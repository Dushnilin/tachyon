#!/usr/bin/env ucode
// Isolated regressions; DNS, UCI and live routes are not changed.
let module = require("service.smart_detect");
let checks = 0;
function check(ok, name) { if (!ok) die("FAIL: " + name + "\n"); checks++; }
let state = module.observe_dns({}, {signature:"main",busy:false}, 100);
check(!state.ready, "initial resolver observation settles");
state = module.observe_dns(state, {signature:"main",busy:false}, 129);
check(!state.ready, "settle interval not over");
state = module.observe_dns(state, {signature:"main",busy:false}, 130);
check(state.ready, "stable resolver ready after thirty seconds");
state = module.observe_dns(state, {signature:"fallback",busy:false}, 135);
check(!state.ready, "DNS failover starts a new settle interval");
state = module.observe_dns(state, {signature:"fallback",busy:false}, 165);
check(state.ready, "healthy fallback becomes eligible");
state = module.observe_dns(state, {signature:"fallback",busy:true}, 170);
check(!state.ready, "failover transaction or DNS fault blocks addition");
state = module.observe_dns(state, {signature:"fallback",busy:false}, 199);
check(!state.ready, "fault recovery also settles");
state = module.observe_dns(state, {signature:"fallback",busy:false}, 200);
check(state.ready, "stable recovery ready");
state = module.observe_dns(state, {signature:"new-core",busy:false}, 201);
check(!state.ready, "core PID change invalidates old observation");
state = module.observe_dns(state, {signature:"new-core",busy:false}, 180);
check(!state.ready && state.changed_at == 180, "clock going backwards restarts grace");
check(!module.observe_dns({}, {signature:null,busy:false}, 1000).ready, "missing runtime DNS cannot be trusted");
let zero = module.observe_dns({}, {signature:"main",busy:false}, 0);
check(module.observe_dns(zero, {signature:"main",busy:false}, 30).ready, "zero timestamp is a valid observation");
check(module.probe_kind(0) == "ok", "successful HTTP response");
for (let code in [5,6]) check(module.probe_kind(code) == "dns", "DNS error " + code);
for (let code in [7,16,18,28,35,52,55,56,92])
    check(module.probe_kind(code) == "transport", "transport evidence " + code);
for (let code in [1,2,3,23,26,27,58,60,77,97,255])
    check(module.probe_kind(code) == "local", "local/certificate error excluded " + code);
for (let code in [0,6,28,60,255])
    check(module.probe_status(["sh","-c","exit " + code]) == code,
        "real process exit status preserved " + code);
print(sprintf("PASS: %d DNS guard checks\n", checks));
