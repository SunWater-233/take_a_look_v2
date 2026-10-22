//! Local-only test gateway using the current sibling EmberMobile implementation.
use ember_v2::{
    pairing::Pairing,
    server::{Backend, BackendResult, Fault, Server},
    wire::{Chunk, Subscription},
};
use serde_json::{json, Value};
use std::{io::Write, path::PathBuf, sync::{Arc, Mutex}};
use sha2::{Digest, Sha256};
use tokio::{io::{AsyncBufReadExt, AsyncWriteExt, BufReader}, sync::Notify};

#[derive(Default)]
struct State {
    upload: Vec<u8>, size: usize, hash: String, ready: bool,
    flash: Value, halted: bool, fail_flash: bool, resets: u64, resumes: u64,
}
struct Fixture(Mutex<State>);
impl Fixture {
    fn snapshot(&self) -> Value {
        let state = self.0.lock().unwrap();
        json!({"connection":{"attached":true,"session_id":1},"gdb":{"running":false},
            "flash":state.flash,"firmware":{"received":state.upload.len(),"sha256":state.hash,"ready":state.ready},
            "resets":state.resets,"resumes":state.resumes})
    }
}
fn unavailable<T>() -> BackendResult<T> {
    Err(Fault { code: "unsupported".into(), message: "No fixture hardware".into() })
}
impl Backend for Fixture {
    fn rpc(&self, method: &str, params: Value) -> BackendResult<Value> {
        match method {
            "hello" => Ok(json!({"protocol_version":2})),
            "ping" => Ok(json!({"pong":true})),
            "backend_state" => Ok(self.snapshot()),
            "debug_status" => Ok(json!({"core":{"state":if self.0.lock().unwrap().halted {"halted"} else {"running"}}})),
            "read_registers" => Ok(json!({"registers": (["R0","R1","R2","R3","R12","R13","R14","R15","PSR"].iter()
                .map(|name| json!({"name":name,"value":0x08000000u64})).collect::<Vec<_>>())})),
            "halt" | "resume" | "reset" => {
                let mut state = self.0.lock().unwrap();
                state.halted = method == "halt" || (method == "reset" && params["halt"] == true);
                if method == "resume" { state.resumes += 1; }
                if method == "reset" { state.resets += 1; }
                Ok(json!({}))
            }
            "firmware_begin" => {
                let mut state = self.0.lock().unwrap();
                state.upload.clear(); state.ready = false;
                state.size = params["size"].as_u64().unwrap() as usize;
                state.hash = params["sha256"].as_str().unwrap().into();
                Ok(json!({"id":1}))
            }
            "firmware_finish" => {
                let mut state = self.0.lock().unwrap();
                if state.upload.len() != state.size || format!("{:x}", Sha256::digest(&state.upload)) != state.hash {
                    return Err(Fault {code:"checksum_mismatch".into(),message:"Fixture checksum mismatch".into()});
                }
                state.ready = true;
                Ok(json!({"ready":true,"sha256":state.hash}))
            }
            "firmware_abort" => { self.0.lock().unwrap().upload.clear(); Ok(json!({})) }
            "flash" => {
                let mut state = self.0.lock().unwrap();
                if !state.ready || params["format"] != "elf" || params["session_id"] != 1 {
                    return unavailable();
                }
                state.halted = true;
                state.flash = json!({"id":9,"state":if state.fail_flash {"failed"} else {"succeeded"},
                    "error":if state.fail_flash {Some("Fixture verify failed")} else {None}});
                Ok(json!({"job_id":9}))
            }
            _ => unavailable(),
        }
    }
    fn memory_read(&self, p: Value) -> BackendResult<Vec<u8>> {
        Ok((0..p["length"].as_u64().unwrap()).map(|i| (p["address"].as_u64().unwrap() + i) as u8).collect())
    }
    fn memory_batch(&self, request: ember_v2::memory::ReadRequest, _: ember_v2::memory::ReadContext)
        -> BackendResult<ember_v2::memory::Batch> {
        request.validate()?;
        Ok(ember_v2::memory::Batch {
            epoch: 7, reads: request.ranges.len() as u64,
            data: request.ranges.iter().flat_map(|r| (0..r.length).map(move |i| (r.address + i as u64) as u8)).collect(),
        })
    }
    /// Repeat the same bytes so a client can see how many reads one tick carried.
    fn memory_burst(&self, request: ember_v2::memory::ReadRequest, context: ember_v2::memory::ReadContext,
                    repeat: usize) -> BackendResult<ember_v2::memory::Batch> {
        let batch = self.memory_batch(request, context)?;
        let mut data = Vec::with_capacity(batch.data.len() * repeat);
        for _ in 0..repeat { data.extend_from_slice(&batch.data); }
        Ok(ember_v2::memory::Batch { epoch: batch.epoch, reads: batch.reads * repeat as u64, data })
    }
    fn rtt_read(&self, _: &Subscription, _: usize) -> BackendResult<Chunk> { unavailable() }
    fn rtt_write(&self, _: Value, _: Vec<u8>) -> BackendResult<Value> { unavailable() }
    fn upload(&self, id: u64, offset: usize, bytes: &[u8]) -> BackendResult<Value> {
        let mut state = self.0.lock().unwrap();
        if id != 1 || offset != state.upload.len() || offset + bytes.len() > state.size { return unavailable(); }
        state.upload.extend_from_slice(bytes);
        Ok(json!({"received":state.upload.len()}))
    }
    fn signal(&self) -> Arc<Notify> { Arc::new(Notify::new()) }
}

#[tokio::main]
async fn main() -> ember_v2::Result<()> {
    let directory = PathBuf::from(std::env::args().nth(1).expect("identity directory"));
    let pairing = Pairing::open(&directory.join("identity.json"), "Fixture phone")?;
    let server = Arc::new(Server::bind_with_pairing("127.0.0.1:0".parse()?, "fixture-long-temporary-token", Some(pairing.clone()))?);
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    println!("{}", json!({"v2":server.advertisement,"token":server.token,"tcp_port":tcp.local_addr()?.port()}));
    std::io::stdout().flush()?;
    let running = server.clone();
    let backend = Arc::new(Fixture(Mutex::new(State::default())));
    let gateway_backend = backend.clone();
    tokio::spawn(async move { running.run(gateway_backend).await; });
    let discovery = server.clone();
    tokio::spawn(async move {
        while let Ok((socket, _)) = tcp.accept().await {
            let server = discovery.clone();
            tokio::spawn(async move {
                let (input, mut output) = socket.into_split();
                let mut lines = BufReader::new(input).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    assert_eq!(request["token"], "", "TCP discovery must not receive credentials");
                    let response = json!({"id":request["id"],"ok":true,"result":{"v2":server.advertisement}});
                    if output.write_all(format!("{response}\n").as_bytes()).await.is_err() { break; }
                }
            });
        }
    });
    // Approval is possible only through the fixture's local stdin, like Android UI.
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = input.next_line().await? {
        let command: Value = serde_json::from_str(&line)?;
        let result = match command["operation"].as_str().unwrap_or("") {
            "backend" => backend.snapshot(),
            "fail_flash" => { backend.0.lock().unwrap().fail_flash = true; json!({"ok":true}) }
            "snapshot" => pairing.snapshot(),
            "decide" => {
                pairing.decide(command["id"].as_str().unwrap(), command["accept"].as_bool().unwrap())?;
                json!({"ok":true})
            }
            "forget" => {
                pairing.forget(command["id"].as_str().unwrap(), None)?;
                json!({"ok":true})
            }
            _ => break,
        };
        println!("{result}");
        std::io::stdout().flush()?;
    }
    server.close();
    Ok(())
}
