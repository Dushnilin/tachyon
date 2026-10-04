// Run: ucode -L /usr/lib/tachyon /tmp/test-tachyon-amnezia.uc
// Synthetic keys and documentation IPs; no UCI changes or network traffic.
let wg = require('subscription.wireguard');
let generator = require('singbox.generator_outbounds');
generator.init({runtime_generate_unsupported: message => assert(false, message)});
let key = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";
let links = [
    "vpn://AAADAHjanZFtixoxEMe_SshrV2cfrEvoFtaHnt5xsJ53hWKkZDejhq6JZHOnVvzuJStnX_SdBMLvP_OfTJg5U4lNZdXeKaMpo4uTdlt0qiL5TuMfJWiHSlyL99qNjHZCabSUUXFNBuKwoR1afWYaypbnf_I_o7_Zmdaicb8qo9dqQxk9c3plThmny5l2aNeiwhXnurDqQzh8whPJSD6fjYf528PwsHkcbZrn8TwpJsPJYnKc__i-rX4-vJhyOgScnvKMc51LabFpSEZC6A4GXehGvTjqkLUEYCzqhVHKuX5-ffOOKAXO9WNFMpJ42CntsQ3uxJFkZOB5EZKMRC1FN4pvlHzSNGzbQhBBK705BgiSq_QVfYDgy1Um7fMQpK2c-dqvJYEjhBBB_M1bUEi0hTUOK7-puwbyIrQ0u1crVI3Wz8VozvVYNaKscWTMb4W36LJAtO0G3staVXf1Kyw2W2FR3lU90XJvlHYkI8sIIGSyTBkLV6wfpu2M87o2B5Szwn8auu3pQYcw1vPpAm2jGofaPSHuRa0-0G-nH8R9zjWnF3q5rC5_AWxQ8KA",
    "vpn://AAADAHgBq1ZKSS1OLsosKMnMz1OyUgquzCvJSC3JTFZwzM1LrcpMVNJRSklNSyzNKXHOzytJzMxLLVKyUkqESOomlqcr6Sglw2SKlayiqxFcDIUg0qpaKSexuCQ-OT8vLTNdyUqpOkYJwo5RsopRivbMK0ktSktMTo2NickLKMosSyxJ9U6tVLBVcAz0dHFyDHV3Kk_3ck4v9nUJNAlwdXINdq0IDHPLSI50D8pP8nAySPWodLSNiclzTEkpSi0uVrBVMDTQMzfXM9Az0jc20lFISzEwsLIy0jc0soiJyfMNCQWpMLIwiInJ80pWsFUwATFyM_NATLBgbmKFgq2COYgdbKhgq2AEZhnBWcZwlgmM5WEIttZA18gAzAUpNjYw0DWBcEE6TA0MdM0gXBOw8Qa6FmCuJ0ivTZKCQYWBoYGRgbEdSElqYkpqUUBRfklqMiimyAqQoMS8lPzckKLEzJzUIlC45OfFxOS5ZBYnJuWkOufnZ2emwkWjA1JTi8AxUJqUk5lMln0BRanFGYlFqSlk6XbNSynIz8wrUbBViDYyMDC0SkmysLIyjLUyNbQAh7FjTk5-eWqKZwDI0QZ6YKhvoKNgZaUPkg5ILSrOLC5JzSvxTk0tSMzJLEsFxY6prrFpTExejFKtUm1tbC0AbFDwoA",
    "vpn://AAADAHgBAQAD__x7ImRlc2NyaXB0aW9uIjoiU3ludGhldGljIEFtbmV6aWEiLCJkZWZhdWx0Q29udGFpbmVyIjoiYW1uZXppYS1hd2ciLCJjb250YWluZXJzIjpbeyJjb250YWluZXIiOiJhbW5lemlhLWF3ZyIsImF3ZyI6eyJsYXN0X2NvbmZpZyI6IntcImNvbmZpZ1wiOlwiW0ludGVyZmFjZV1cXG5Qcml2YXRlS2V5ID0gQVFJREJBVUdCd2dKQ2dzTURRNFBFQkVTRXhRVkZoY1lHUm9iSEIwZUh5QT1cXG5BZGRyZXNzID0gMTAuNzcuMC4yLzMyLCBmZDAwOjoyLzEyOFxcbk1UVSA9IDEyODBcXG5KYyA9IDRcXG5KbWluID0gNDBcXG5KbWF4ID0gNzBcXG5TMSA9IDIwXFxuUzIgPSAyMFxcblMzID0gMjBcXG5TNCA9IDIwXFxuSDEgPSAxMDAtMjAwXFxuSDIgPSAzMDAtNDAwXFxuSDMgPSA1MDAtNjAwXFxuSDQgPSA3MDAtODAwXFxuSTEgPSA8YiAweDAxMDIwMz5cXG5IZWFkZXJQcm90ZWN0aW9uS2V5ID0gQVFJREJBVUdCd2dKQ2dzTURRNFBFQkVTRXhRVkZoY1lHUm9iSEIwZUh5QT1cXG5SYW5kb21UcmFpbGVycyA9IG9uXFxuRGlzYWJsZUNvb2tpZXMgPSBvblxcbltQZWVyXVxcblB1YmxpY0tleSA9IEFRSURCQVVHQndnSkNnc01EUTRQRUJFU0V4UVZGaGNZR1JvYkhCMGVIeUE9XFxuUHJlc2hhcmVkS2V5ID0gQVFJREJBVUdCd2dKQ2dzTURRNFBFQkVTRXhRVkZoY1lHUm9iSEIwZUh5QT1cXG5FbmRwb2ludCA9IFsyMDAxOmRiODo6MV06NTE4MjBcXG5BbGxvd2VkSVBzID0gMC4wLjAuMC8wLCA6Oi8wXFxuUGVyc2lzdGVudEtlZXBhbGl2ZSA9IDI1LTM1XFxuXCJ9In19XX1sUPCg",
    "vpn://AAACNXjanVHbboJAEH3fr9gPEBgWqISUJqBU0JjgrUljfFjYUTdF1izUy983a_0CMw9nzsycuWS2Rduj3vMad6TU8sJ7nOGdxjRZFOM02UzS62E6OnTz8cIvszRbZbfF1-ex_p4sVZWngPk9iUkihMauozF1wR4ObbCZ47EB3QuAKGKOy0IyX29MnoVApjWNqU-mJ9kaB8j0xG80pkMgK5fGlAFZsSd6T_T_MXcfQ8BiACQ3RR6A5RtiKgMA680Q_9EOrBCAFEbzXlG4gQsMvA-SIxeoS616rHup2hdOXvJWqNNac9mgNperloxlx6sGR0r9SHzGtiWi3pHyt2pk_cKcUmN35BrFC9qsFWcl257GdMsA3EhUYRS5uyhwQwYkaRp1RVGUZlWwH-bAgEaRA6RE3cmux7afIZ55Iy9oPhBYXkD-AHW0nu0",
    "vpn://AAADAnjanZHdjtowEIVfxfI1gYkDBVlNpfDThV2tFJbdShVGlRMPYDXYyPEuUMS7Vw5aetE75JvvzJyZsWbOVGFdOr332hrK6eJk_Ba9Lkm2M_hHS9qiCtfyvfIja7zUBh3lVF6TkTxsGG3R8jNVU748_5P_O-VhQ_mZVrL2v0pr1npDOT0LemVBuaDLmfHo1rLElRAmd_pDenzCE0lJNp-Nh9nbw_CweRxt6ufxvJtPhpPF5Dj_8X1b_nx4scV0CDg9ZakQJlPKYV2TlMTQ7vfb0GadhLXIWgFwzjoxGwhhnl_fgoMNQAjzWJKUdAPstAnYBHfySFLSD7yISUpYQ-xGyY26nzSNm7EQMWhkMCcAUfcqQ0UPIPpyld2mPUSDRs5C7deCwBFiYJB8CxaUCl3urMcy3OquhbxIo-zu1UldoQt7sUYIM9a1LCocWftb4y26zBFdc4H3otLlXfNyh_VWOlR3VU-M2lttPEnJkgHEXBUDzuMV78WDZsdZVdkDqlkePg3t5nWgRTjvhHSOrta1R-OfEPey0h8YrtOLkp4QRtALvVxWl7-2BfEE",
    "vpn://AAADBXjanZHPahsxEMZfRejstWfXdr2IbmH9J7ETAuvELhTLFHk1dkTXktFuYifGkDfpK5RCLjn0GTZvVLQm7qE3IxC_b-YbjZjZU4l5atWmUEZTRsuf7y_ln_J3-fr-Ur6Vv8h0cuGFtEYlLsVDVvSMLoTSaCmjYq3xWQlPbFe0RtOPTE7ZbP9P_md0N9vTTOTF99TopVpRRvecHplTxulspAu0S5HinHOdWPUoCrzGJxKReDzqd-PpZXe7uuqt8pv-uJUMuoO7wW789eI-_XZ5axbDLuDwKY4417GUFvOcRMSHeqdTh3rQaAY1spQAjAUNPwg51zeTqXMEIXCur1ISkZaDtdIOq-Ba7EhEOo7vfBKRoKLgRM0TtT5o6FdtwQugks7cBPBaR-kq2gDep6NsVc-DF1Zy5Go_LwjswIcAml-cBYVEm1hTYOrWddZAboWWZj2xQmVo3VyM5lz3VS4WGfaM-aHwFJ0liLbawMMiU-lZ_RKL-b2wKM-qHmi5MUoXJCKzAMBnchEy5s9Z2w-rGcdZZrYoR4n7NNSr04AaYazh0gnaXOUF6uIacSMy9YhuO22v2eZcc3qgh8P88BexZvck"
];
for (let link in links) {
    let endpoint = wg.from_vpn(link);
    assert(endpoint && wg.has_awg(endpoint), 'compressed WG/AWG import');
    assert(endpoint.private_key == key && endpoint.peers[0].public_key == key &&
        endpoint.header_protection_key == key, 'all keys preserved');
    assert(endpoint.h1 == '100-200' && endpoint.random_trailers && endpoint.disable_cookies &&
        endpoint.peers[0].persistent_keepalive_interval == '25-35', 'AWG flags and ranges preserved');
    assert(endpoint.peers[0].address == '2001:db8::1' && endpoint.peers[0].port == 51820, 'IPv6 peer');
    let manual = generator.manual_link_outbound(link, 'test-amnezia');
    assert(manual.tag == 'test-amnezia' && manual.share_link == null, 'core endpoint generation');
}
assert(wg.from_vpn(links[5]).tag == 'Проверка UTF-8', 'UTF-8 name preserved');
let encoded = replace(replace(substr(links[0], 6), /-/g, '+'), /_/g, '/');
while (length(encoded) % 4) encoded += '=';
let bytes = b64dec(encoded);
function uri(data) { return 'vpn://' + replace(replace(b64enc(data), /\+/g, '-'), /\//g, '_'); }
let bad_checksum = substr(bytes, 0, length(bytes)-1) + chr(ord(bytes, length(bytes)-1) ^ 1);
for (let data in [bad_checksum, substr(bytes, 0, length(bytes)-3), bytes + 'extra',
    chr(0,1,0,1) + substr(bytes,4), chr(0,0,0,20) + substr(bytes,4)])
    assert(wg.from_vpn(uri(data)) == null, 'corrupt checksum/size/truncation/trailing data rejected');
for (let data in [{containers:[{container:'amnezia-openvpn',openvpn:{last_config:'{}'}}]},
    {containers:[{container:'amnezia-awg',awg:{last_config:'{}'}}]}])
    assert(wg.from_vpn(uri(sprintf('%J', data))) == null, 'unsupported or incomplete container rejected');
print('PASS: Amnezia stored/fixed/dynamic zlib, AWG2, compressed INI, keys/ranges/flags, corruption and container validation\n');
