// Run: ucode -L /usr/lib/tachyon /tmp/test-tachyon-awg-labels.uc
// Synthetic name/keys and documentation IP only; no UCI writes or network.
let wg = require('subscription.wireguard');
let gen = require('singbox.generator_outbounds');
let subscription = require('singbox.subscription');
gen.init({runtime_generate_unsupported: message => assert(false, message)});
let bytes=''; for (let i=1; i<=32; i++) bytes+=chr(i);
let key=b64enc(bytes);
let conf='[Interface]\nPrivateKey = '+key+'\nAddress = 10.77.0.2/32\nJc = 4\n[Peer]\nPublicKey = '+key+'\nEndpoint = 192.0.2.1:51820\n';
let payload={description:'My Amnezia',defaultContainer:'amnezia-awg2',containers:[{container:'amnezia-awg2',awg:{last_config:sprintf('%J',{config:conf})}}]};
let raw='vpn://'+b64enc(sprintf('%J',payload));
let info={}; let endpoint=gen.manual_link_outbound(raw, 'vpn-1-out', info);
assert(info.name=='My Amnezia' && endpoint.tag=='vpn-1-out' && endpoint.remark==null, 'name returned separately; core tag/schema unchanged');
let state={servers:{},outboundMetadata:{names:{},prefixes:{},protocols:{},transports:{},securities:{}}};
subscription.remember_outbound_metadata(state,endpoint.tag,info.name,endpoint);
assert(state.outboundMetadata.names['vpn-1-out']=='My Amnezia' && state.outboundMetadata.protocols['vpn-1-out']=='amneziawg' &&
    state.outboundMetadata.transports['vpn-1-out']==null, 'AWG metadata and no fake TCP transport');
assert(state.servers['vpn-1-out']=='192.0.2.1' && state.outboundMetadata.ports['vpn-1-out']=='51820', 'AWG server address and port preserved');
let plain=wg.from_conf(replace(conf,'Jc = 4\n',''),'','Plain WG');
subscription.remember_outbound_metadata(state,'wg-test','Plain WG',plain);
assert(state.outboundMetadata.protocols['wg-test']=='wireguard', 'plain WG label unchanged');
let h2={type:'hysteria2',tag:'h2-test',server:'192.0.2.1',server_port:443};
subscription.remember_outbound_metadata(state,'h2-test','H2',h2);
assert(state.outboundMetadata.protocols['h2-test']=='hysteria2', 'existing protocols unchanged');
print('PASS: imported name, stable core tag, AWG and ordinary WG/HY2 metadata\n');
