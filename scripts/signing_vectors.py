import ast, sys, json, collections, base64, hashlib, hmac, os, time
src = open(sys.argv[1]).read()
tree = ast.parse(src)
keep = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in ("b64","sign","derive_password","add_user_payload")]
for n in keep:  # strip annotations so 3.9 can exec them
    n.returns = None
    for a in n.args.args + n.args.kwonlyargs: a.annotation = None
ns = {"base64":base64,"hashlib":hashlib,"hmac":hmac,"os":os,"time":time,"Any":object}
exec(compile(ast.Module(body=keep, type_ignores=[]), "_auth", "exec"), ns)
user = [ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.AnnAssign) and n.target.id=="DEFAULT_USERNAME"][0]
Cred = collections.namedtuple("Cred","username password")
c = Cred(user, ns["derive_password"](user))
dumps = lambda o: json.dumps(o, separators=(",",":"), ensure_ascii=False).encode()
cases = [
  ("https://192.168.1.78:4430/api/setData", dumps({"path":"player:volume","role":"value","value":{"type":"i32_","i32_":42}}), "AbCdEfGh", 1700000000000),
  ("https://192.168.1.78:4430/api/event/modifyQueue", dumps({"subscribe":[{"path":"player:volume","type":"itemWithValue"}],"unsubscribe":[]}), "q1w2e3r4", 1732400000123),
  ("https://192.168.1.78:4430/api/setData", dumps({"path":"settings:/deviceName","role":"value","value":{"type":"string_","string_":"Café ✓"}}), "Zz9+/A==", 1),
  ("https://192.168.1.78:4430/api/getData?path=settings%3A%2FdeviceName&roles=value", None, "nonce000", 1700000000000),
]
out = {"username": user, "password": c.password, "addUserBody": dumps(ns["add_user_payload"](c)).decode(), "cases": []}
for url, body, nonce, ts in cases:
    out["cases"].append({"url":url,"body":None if body is None else body.decode(),"nonce":nonce,"ts":ts,
                         "header": ns["sign"](c, url, body, nonce=nonce, timestamp_ms=ts)})
print(json.dumps(out, indent=1, ensure_ascii=False))
