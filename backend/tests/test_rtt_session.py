from types import SimpleNamespace

import pytest

from take_a_look_backend.backends.rtt_session import RttSessionManager


class Channel:
    def __init__(self,number):
        self.number=number
        self.name=f'channel-{number}'
        self.reads=0
    def read(self):
        self.reads+=1
        return bytes([self.number])


class Target:
    def __init__(self):
        self.opens=self.closes=0
        self.channels=[Channel(0),Channel(1)]
    def open_rtt(self,address):
        self.opens+=1
        return SimpleNamespace(up_channels=self.channels,down_channels=[],transport_name='test',close=self.close)
    def close(self):self.closes+=1


def test_two_consumers_share_transport_and_release_only_their_own_channels():
    target=Target();sessions=RttSessionManager()
    first=sessions.open(target);second=sessions.open(target)
    assert target.opens==1
    assert first.up_channels[0].read()==b'\x00'
    assert second.up_channels[1].read()==b'\x01'
    first.close()
    assert target.closes==0
    assert second.up_channels[1].read()==b'\x01'
    second.close()
    assert target.closes==1


def test_channel_has_one_reader_and_a_failed_claim_consumes_no_bytes():
    target=Target();sessions=RttSessionManager()
    first=sessions.open(target);second=sessions.open(target)
    first.up_channels[0].read()
    with pytest.raises(RuntimeError,match='占用'):second.up_channels[0].read()
    assert target.channels[0].reads==1
    first.close()
    assert second.up_channels[0].read()==b'\x00'
    second.close()


def test_closed_lease_cannot_read_or_stop_a_replacement_session():
    target=Target();sessions=RttSessionManager()
    old=sessions.open(target);sessions.close();new=sessions.open(target)
    with pytest.raises(RuntimeError,match='关闭'):old.up_channels[0].read()
    old.close()
    assert target.closes==1
    assert new.up_channels[0].read()==b'\x00'
    new.close()
    assert target.closes==2


def test_different_target_or_control_block_is_not_silently_rebound():
    target=Target();sessions=RttSessionManager();lease=sessions.open(target,0x20001000)
    with pytest.raises(RuntimeError):sessions.open(target,0x20002000)
    with pytest.raises(RuntimeError):sessions.open(Target(),0x20001000)
    lease.close()
