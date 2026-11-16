"""DWARF operations that can be resolved without reading or halting a target."""
from __future__ import annotations


def inherited_attribute(die, name: str, seen=None):
    """Return both the attribute and its owning DIE (references may cross CUs)."""
    if die is None:
        return None
    seen = set() if seen is None else seen
    if id(die) in seen or len(seen) >= 64:
        return None
    seen.add(id(die))
    if name in die.attributes:
        return die.attributes[name], die
    for reference in ("DW_AT_specification", "DW_AT_abstract_origin"):
        if reference not in die.attributes:
            continue
        try:
            result = inherited_attribute(die.get_DIE_from_attribute(reference), name, seen)
        except (KeyError, ValueError):
            continue
        if result is not None:
            return result
    return None


def static_expression(attribute, parser, *, member=False) -> int | None:
    """Evaluate constant address arithmetic; reject runtime/value/piece locations.

    Each stack item carries whether it is based on an address. A member
    expression starts with the containing object's address, represented by zero.
    Unsupported operations never yield a partially evaluated address.
    """
    if attribute is None or not isinstance(attribute.value, (bytes, bytearray, list, tuple)):
        return None
    try:
        operations = parser.parse_expr(attribute.value)
    except Exception:
        return None
    if not operations:
        return None
    stack = [(0, True)] if member else []
    address_size = None
    constants = {
        "DW_OP_const1u", "DW_OP_const1s", "DW_OP_const2u", "DW_OP_const2s",
        "DW_OP_const4u", "DW_OP_const4s", "DW_OP_const8u", "DW_OP_const8s",
        "DW_OP_constu", "DW_OP_consts",
    }
    for index, operation in enumerate(operations):
        name, args = operation.op_name, operation.args
        if name == "DW_OP_addr" and args and not member:
            end = operations[index + 1].offset if index + 1 < len(operations) else len(attribute.value)
            address_size = end - operation.offset - 1
            stack.append((int(args[0]), True))
        elif name in constants and args:
            stack.append((int(args[0]), False))
        elif name.startswith("DW_OP_lit") and name[9:].isdigit():
            stack.append((int(name[9:]), False))
        elif name == "DW_OP_plus_uconst" and args and stack:
            value, address = stack.pop()
            stack.append((value + int(args[0]), address))
        elif name in {"DW_OP_plus", "DW_OP_minus"} and len(stack) >= 2:
            right, right_address = stack.pop()
            left, left_address = stack.pop()
            if right_address and (left_address or name == "DW_OP_minus"):
                return None
            value = left + right if name == "DW_OP_plus" else left - right
            stack.append((value, left_address or right_address))
        elif name == "DW_OP_nop":
            continue
        else:
            return None
    if len(stack) != 1 or not stack[0][1] or stack[0][0] < 0:
        return None
    result = stack[0][0]
    if isinstance(address_size, int) and result >= 1 << (8 * address_size):
        return None
    return result
