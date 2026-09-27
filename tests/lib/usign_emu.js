#!/usr/bin/env node
/**
 * Portable usign / signify CLI emulator using Node.js standard crypto module.
 * Provides identical CLI and binary format compatibility with OpenWrt usign:
 *   -V -m <file> -p <pubkey> [-x <sigfile>] [-q]
 *   -S -m <file> -s <seckey> [-x <sigfile>]
 *   -G -p <pubkey> -s <seckey> [-c <comment>]
 *   -F -p <pubkey> / -s <seckey> / -x <sigfile>
 */
const fs = require('fs');
const crypto = require('crypto');

function parseArgs(args) {
    let mode = '';
    let messageFile = '';
    let pubkeyFile = '';
    let seckeyFile = '';
    let sigFile = '';
    let comment = '';
    let quiet = false;

    for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        if (arg === '-V' || arg === '-S' || arg === '-G' || arg === '-F') {
            mode = arg;
        } else if (arg === '-q') {
            quiet = true;
        } else if (arg === '-m' && i + 1 < args.length) {
            messageFile = args[++i];
        } else if (arg === '-p' && i + 1 < args.length) {
            pubkeyFile = args[++i];
        } else if (arg === '-s' && i + 1 < args.length) {
            seckeyFile = args[++i];
        } else if (arg === '-x' && i + 1 < args.length) {
            sigFile = args[++i];
        } else if (arg === '-c' && i + 1 < args.length) {
            comment = args[++i];
        }
    }

    if (!sigFile && messageFile) {
        sigFile = messageFile + '.sig';
    }

    return { mode, messageFile, pubkeyFile, seckeyFile, sigFile, comment, quiet };
}

function parsePubkey(file) {
    const content = fs.readFileSync(file, 'utf8');
    const lines = content.trim().split(/\r?\n/).filter(Boolean);
    const b64 = lines[lines.length - 1].trim();
    const buf = Buffer.from(b64, 'base64');
    if (buf.length < 42) {
        throw new Error('Invalid public key length: ' + buf.length);
    }
    const sigalg = buf.slice(0, 2).toString('ascii');
    if (sigalg !== 'Ed') {
        throw new Error('Unsupported sigalg: ' + sigalg);
    }
    const keynum = buf.slice(2, 10);
    const pubkey = buf.slice(10, 42);
    return { keynum, pubkey };
}

function parseSeckey(file) {
    const content = fs.readFileSync(file, 'utf8');
    const lines = content.trim().split(/\r?\n/).filter(Boolean);
    const b64 = lines[lines.length - 1].trim();
    const buf = Buffer.from(b64, 'base64');
    if (buf.length < 104) {
        throw new Error('Invalid secret key length: ' + buf.length);
    }
    const sigalg = buf.slice(0, 2).toString('ascii');
    if (sigalg !== 'Ed') {
        throw new Error('Unsupported sigalg: ' + sigalg);
    }
    const keynum = buf.slice(32, 40);
    const seed = buf.slice(40, 72);
    const pubkey = buf.slice(72, 104);
    return { keynum, seed, pubkey };
}

function parseSignature(file) {
    const content = fs.readFileSync(file, 'utf8');
    const lines = content.trim().split(/\r?\n/).filter(Boolean);
    if (lines.length !== 2 && lines.length !== 4) {
        throw new Error('Invalid signature file format: expected 2 or 4 lines, got ' + lines.length);
    }
    // Line 1 is untrusted comment, Line 2 is base64(2 bytes "Ed" + 8 bytes keynum + 64 bytes sig)
    const b64 = lines[1].trim();
    const buf = Buffer.from(b64, 'base64');
    if (buf.length < 74) {
        throw new Error('Invalid signature length: ' + buf.length);
    }
    const sigalg = buf.slice(0, 2).toString('ascii');
    if (sigalg !== 'Ed') {
        throw new Error('Unsupported sigalg: ' + sigalg);
    }
    const keynum = buf.slice(2, 10);
    const sig = buf.slice(10, 74);
    return { keynum, sig };
}

function ed25519KeyFromSeed(seed) {
    // PKCS#8 DER header for Ed25519 private key with 32-byte seed
    const pkcs8Prefix = Buffer.from('302e020100300506032b657004220420', 'hex');
    const der = Buffer.concat([pkcs8Prefix, seed]);
    return crypto.createPrivateKey({ key: der, format: 'der', type: 'pkcs8' });
}

function ed25519KeyFromPubkey(pubkey) {
    // SPKI DER header for Ed25519 public key (32 bytes)
    const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
    const der = Buffer.concat([spkiPrefix, pubkey]);
    return crypto.createPublicKey({ key: der, format: 'der', type: 'spki' });
}

function main() {
    const opts = parseArgs(process.argv.slice(2));

    if (opts.mode === '-G') {
        if (!opts.pubkeyFile || !opts.seckeyFile) {
            console.error('Usage: usign_emu.js -G -p <pubkey> -s <seckey> [-c <comment>]');
            process.exit(1);
        }
        const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
        const rawPub = publicKey.export({ type: 'spki', format: 'der' }).slice(-32);
        const rawPriv = privateKey.export({ type: 'pkcs8', format: 'der' }).slice(-32);
        const keynum = crypto.randomBytes(8);
        const hexId = keynum.toString('hex');

        // Build pubkey file
        const pubBlob = Buffer.concat([Buffer.from('Ed', 'ascii'), keynum, rawPub]);
        const comment = opts.comment || 'public key ' + hexId;
        const pubText = 'untrusted comment: ' + comment + '\n' + pubBlob.toString('base64') + '\n';
        fs.writeFileSync(opts.pubkeyFile, pubText);

        // Build secret key file (unencrypted, kdfrounds=0)
        const salt = crypto.randomBytes(16);
        const seckeyData = Buffer.concat([rawPriv, rawPub]);
        const checksum = crypto.createHash('sha512').update(seckeyData).digest().slice(0, 8);
        const kdfrounds = Buffer.alloc(4); // 0
        const secBlob = Buffer.concat([
            Buffer.from('Ed', 'ascii'),
            Buffer.from('BK', 'ascii'),
            kdfrounds,
            salt,
            checksum,
            keynum,
            seckeyData
        ]);
        const secComment = 'private key ' + hexId;
        const secText = 'untrusted comment: ' + secComment + '\n' + secBlob.toString('base64') + '\n';
        fs.writeFileSync(opts.seckeyFile, secText);
        fs.chmodSync(opts.seckeyFile, 0o600);
        process.exit(0);
    }

    if (opts.mode === '-S') {
        if (!opts.messageFile || !opts.seckeyFile || !opts.sigFile) {
            console.error('Usage: usign_emu.js -S -m <file> -s <seckey> [-x <sigfile>]');
            process.exit(1);
        }
        const { keynum, seed } = parseSeckey(opts.seckeyFile);
        const privKey = ed25519KeyFromSeed(seed);
        const data = fs.readFileSync(opts.messageFile);
        const sig = crypto.sign(null, data, privKey);
        const sigBlob = Buffer.concat([Buffer.from('Ed', 'ascii'), keynum, sig]);
        const hexId = keynum.toString('hex');
        const sigText = 'untrusted comment: signed by key ' + hexId + '\n' + sigBlob.toString('base64') + '\n';
        fs.writeFileSync(opts.sigFile, sigText);
        process.exit(0);
    }

    if (opts.mode === '-V') {
        if (!opts.messageFile || !opts.pubkeyFile || !opts.sigFile) {
            console.error('Usage: usign_emu.js -V -m <file> -p <pubkey> [-x <sigfile>] [-q]');
            process.exit(1);
        }
        try {
            const { keynum: pubKeynum, pubkey } = parsePubkey(opts.pubkeyFile);
            const { keynum: sigKeynum, sig } = parseSignature(opts.sigFile);
            if (!pubKeynum.equals(sigKeynum)) {
                if (!opts.quiet) console.error('verification failed: key ID mismatch');
                process.exit(1);
            }
            const pubKey = ed25519KeyFromPubkey(pubkey);
            const data = fs.readFileSync(opts.messageFile);
            const ok = crypto.verify(null, data, pubKey, sig);
            if (!ok) {
                if (!opts.quiet) console.error('verification failed');
                process.exit(1);
            }
            if (!opts.quiet) console.log('OK');
            process.exit(0);
        } catch (e) {
            if (!opts.quiet) console.error('verification failed: ' + e.message);
            process.exit(1);
        }
    }

    if (opts.mode === '-F') {
        if (opts.pubkeyFile) {
            const { keynum } = parsePubkey(opts.pubkeyFile);
            console.log(keynum.toString('hex'));
            process.exit(0);
        } else if (opts.seckeyFile) {
            const { keynum } = parseSeckey(opts.seckeyFile);
            console.log(keynum.toString('hex'));
            process.exit(0);
        } else if (opts.sigFile) {
            const { keynum } = parseSignature(opts.sigFile);
            console.log(keynum.toString('hex'));
            process.exit(0);
        }
        console.error('Usage: usign_emu.js -F -p <pubkey> | -s <seckey> | -x <sigfile>');
        process.exit(1);
    }

    console.error('Usage: usign_emu.js <-V|-S|-G|-F> <options>');
    process.exit(1);
}

main();
