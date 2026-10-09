"""Pretty-print Blueprint bytecode dumped by tools/bpdump (extracted/json_bp) as pseudo-code (recon/ANIMATION.md).

usage: python tools/bp_pretty.py <json_bp file> [function-name-substring]
"""
import json
import sys


def name(o):
    if isinstance(o, dict):
        if "Property" in o:
            return o["Property"].get("Name", "?")
        if "ObjectName" in o:
            n = o["ObjectName"]
            return n.split("'")[1] if "'" in n else n
        if "Name" in o:
            return o["Name"]
    return str(o)


def ex(e):
    if e is None:
        return "None"
    if not isinstance(e, dict):
        return str(e)
    t = e.get("Token", "")
    if t in ("EX_LocalVariable", "EX_InstanceVariable", "EX_LocalOutVariable", "EX_DefaultVariable"):
        p = "self." if t == "EX_InstanceVariable" else ""
        return p + name(e.get("Variable"))
    if t in ("EX_IntConst", "EX_FloatConst", "EX_ByteConst", "EX_Int64Const", "EX_UInt64Const", "EX_IntConstByte"):
        return str(e.get("Value"))
    if t in ("EX_NameConst", "EX_StringConst", "EX_UnicodeStringConst"):
        return repr(e.get("Value"))
    if t == "EX_TextConst":
        return repr(e.get("Value"))
    if t in ("EX_True", "EX_False", "EX_Self", "EX_NoObject", "EX_Nothing", "EX_IntZero", "EX_IntOne"):
        return {"EX_True": "true", "EX_False": "false", "EX_Self": "self", "EX_NoObject": "null",
                "EX_Nothing": "", "EX_IntZero": "0", "EX_IntOne": "1"}[t]
    if t == "EX_ObjectConst":
        return name(e.get("Value") or e.get("Object"))
    if t in ("EX_VectorConst", "EX_RotationConst"):
        return json.dumps(e.get("Value"))
    if t in ("EX_FinalFunction", "EX_LocalFinalFunction", "EX_CallMath", "EX_VirtualFunction",
             "EX_LocalVirtualFunction", "EX_CallMulticastDelegate"):
        f = e.get("Function") or e.get("VirtualFunctionName") or e.get("StackNode")
        fn = name(f) if isinstance(f, dict) else str(f)
        return f"{fn}({', '.join(ex(p) for p in e.get('Parameters', []))})"
    if t == "EX_Context" or t == "EX_Context_FailSilent":
        return f"{ex(e.get('ObjectExpression'))}.{ex(e.get('ContextExpression'))}"
    if t == "EX_InterfaceContext":
        return ex(e.get("InterfaceValue"))
    if t == "EX_StructMemberContext":
        return f"{ex(e.get('StructExpression'))}.{name(e.get('Property'))}"
    if t in ("EX_DynamicCast", "EX_MetaCast", "EX_ObjToInterfaceCast", "EX_CrossInterfaceCast",
             "EX_InterfaceToObjCast"):
        return f"cast<{name(e.get('ClassPtr') or e.get('Class'))}>({ex(e.get('Target') or e.get('CastExpression'))})"
    if t == "EX_PrimitiveCast":
        return f"{e.get('ConversionType', 'cast')}({ex(e.get('Target'))})"
    if t == "EX_StructConst":
        return f"{name(e.get('Struct'))}{{{', '.join(ex(p) for p in e.get('Properties', []))}}}"
    if t == "EX_ArrayConst":
        return f"[{', '.join(ex(p) for p in e.get('Elements', []))}]"
    if t == "EX_ArrayGetByRef":
        return f"{ex(e.get('ArrayVariable'))}[{ex(e.get('ArrayIndex'))}]"
    if t == "EX_SwitchValue":
        cases = ", ".join(f"{ex(c.get('CaseIndexValueTerm'))}: {ex(c.get('CaseTerm'))}" for c in e.get("Cases", []))
        return f"switch({ex(e.get('IndexTerm'))}){{{cases}, default: {ex(e.get('DefaultTerm'))}}}"
    if t == "EX_BindDelegate":
        return f"bind({e.get('FunctionName')})"
    if t == "EX_SkipOffsetConst":
        return str(e.get("Value"))
    rest = {k: v for k, v in e.items() if k not in ("Token", "StatementIndex", "ObjectPath")}
    return f"{t}{json.dumps(rest)[:200]}"


def st(e):
    t = e.get("Token", "")
    i = e.get("StatementIndex")
    if t in ("EX_Let", "EX_LetBool", "EX_LetObj", "EX_LetWeakObjPtr", "EX_LetDelegate", "EX_LetMulticastDelegate",
             "EX_LetValueOnPersistentFrame"):
        lhs = ex(e.get("Variable")) if "Variable" in e else name(e.get("DestinationProperty"))
        rhs = e.get("Expression") or e.get("Assignment") or e.get("AssignmentExpression")
        return f"{i:5}: {lhs} = {ex(rhs)}"
    if t == "EX_JumpIfNot":
        return f"{i:5}: if not ({ex(e.get('BooleanExpression'))}) goto {e.get('CodeOffset')}"
    if t == "EX_Jump":
        return f"{i:5}: goto {e.get('CodeOffset')}"
    if t == "EX_PushExecutionFlow":
        return f"{i:5}: push {e.get('PushingAddress')}"
    if t == "EX_PopExecutionFlowIfNot":
        return f"{i:5}: pop if not ({ex(e.get('BooleanExpression'))})"
    if t == "EX_PopExecutionFlow":
        return f"{i:5}: pop"
    if t == "EX_ComputedJump":
        return f"{i:5}: goto *{ex(e.get('CodeOffsetExpression'))}"
    if t == "EX_Return":
        return f"{i:5}: return {ex(e.get('Expression'))}"
    if t == "EX_EndOfScript":
        return f"{i:5}: end"
    return f"{i:5}: {ex(e)}"


def main():
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    want = sys.argv[2] if len(sys.argv) > 2 else ""
    for e in d:
        if e.get("Type") == "Function" and want.lower() in e["Name"].lower() and e.get("ScriptBytecode"):
            print(f"=== {e['Name']}")
            for s in e["ScriptBytecode"]:
                print(st(s))


if __name__ == "__main__":
    main()
