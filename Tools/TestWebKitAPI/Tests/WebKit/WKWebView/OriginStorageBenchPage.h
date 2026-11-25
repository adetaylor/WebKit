/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

// The page and worker scripts OriginStorageBench serves. Every shape is a function of `bench.shapes` taking the pass
// number and returning { ms, bytes, checksum, note }: `ms` is the time of the storage calls alone (setup, clearing
// and hashing are outside it), `bytes` what one pass moves, `checksum` a 64-bit digest, as 16 hex digits, of what
// the page observed (names, statuses, headers, bodies, error names). `setup` runs once before the first pass.

namespace TestWebKitAPI::OriginStorageBenchInputs {

static constexpr auto pageScript = R"BENCH(
const bench = (() => {
const origin = location.origin;
const path = url => url.substring(origin.length);

class Hash {
    constructor() { this.a = 0x811c9dc5; this.b = 0x9747b28c; }
    byte(x) { this.a = Math.imul(this.a ^ x, 16777619) >>> 0; this.b = (Math.imul(this.b, 31) + x + 1) >>> 0; }
    num(n) { this.word(n >>> 0); this.word(Math.floor(n / 4294967296) >>> 0); }
    word(w) { this.byte(w & 255); this.byte((w >>> 8) & 255); this.byte((w >>> 16) & 255); this.byte(w >>> 24); }
    str(s) {
        s = String(s);
        this.num(s.length);
        for (let i = 0; i < s.length; ++i) { const c = s.charCodeAt(i); this.byte(c & 255); this.byte(c >>> 8); }
    }
    bytes(u8) {
        this.num(u8.length);
        let i = 0;
        if (u8.byteOffset % 4 == 0) {
            const words = new Uint32Array(u8.buffer, u8.byteOffset, u8.length >>> 2);
            let a = this.a, b = this.b;
            for (let j = 0; j < words.length; ++j) { a = Math.imul(a ^ words[j], 16777619) >>> 0; b = (Math.imul(b, 31) + words[j] + 1) >>> 0; }
            this.a = a; this.b = b;
            i = words.length * 4;
        }
        for (; i < u8.length; ++i) this.byte(u8[i]);
    }
    hex() { return this.a.toString(16).padStart(8, '0') + this.b.toString(16).padStart(8, '0'); }
}

function rng(seed) {
    let state = seed >>> 0;
    return () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state >>> 8; };
}

// One 1 MB source of text; bodies are windows of it.
const source = (() => {
    const next = rng(0x5eed);
    const chunks = [];
    for (let i = 0; i < 1024; ++i) {
        let s = '';
        for (let j = 0; j < 1024; ++j) s += String.fromCharCode(97 + next() % 26);
        chunks.push(s);
    }
    return chunks.join('');
})();
const bodyOf = (i, n) => { const o = (i * 37) % 4096; return source.substring(o, o + n); };

// Payload for OPFS writes: 1 MB of pseudo-random bytes.
const payload = (() => {
    const words = new Uint32Array(262144);
    const next = rng(0xf11e);
    for (let i = 0; i < words.length; ++i) words[i] = next() * 257;
    return new Uint8Array(words.buffer);
})();

class Timer {
    constructor() { this.ms = 0; }
    async time(promise) { const start = performance.now(); try { return await promise; } finally { this.ms += performance.now() - start; } }
}

const batch = async (count, size, make) => {
    for (let i = 0; i < count; i += size) {
        const jobs = [];
        for (let j = i; j < Math.min(count, i + size); ++j) jobs.push(make(j));
        await Promise.all(jobs);
    }
};
const settle = async (promise) => { try { return { value: await promise }; } catch (e) { return { error: e.name }; } };

// ---- Cache Storage ----
const accepts = ['text/plain', 'application/json', 'text/html', 'text/css'];
const sizeOf = i => i % 125 == 0 ? 262144 : 200 + (i * 131) % 1800;
const request = (i, accept = accepts[i & 3]) => new Request(origin + '/r/' + i, { headers: { 'Accept': accept, 'Accept-Language': 'en-US' } });
const varyOf = i => i % 3 == 0 ? 'Accept, Accept-Language' : (i % 3 == 1 ? 'Accept' : null);
const response = (i, generation = 0) => {
    const headers = { 'Content-Type': 'text/plain', 'X-Index': String(i), 'X-Generation': String(generation) };
    if (varyOf(i)) headers['Vary'] = varyOf(i);
    return new Response(bodyOf(i + generation, sizeOf(i)), { status: 200, headers });
};
const totalBytes = count => { let n = 0; for (let i = 0; i < count; ++i) n += sizeOf(i); return n; };

async function populate(name, count) {
    await caches.delete(name);
    const cache = await caches.open(name);
    await batch(count, 50, i => cache.put(request(i), response(i)));
    return cache;
}

async function observe(hash, hit) {
    if (!hit) { hash.str('miss'); return; }
    hash.str(hit.status); hash.str(hit.headers.get('X-Index')); hash.str(hit.headers.get('X-Generation')); hash.str(hit.headers.get('Vary'));
    hash.str(hit.headers.get('Content-Type')); hash.str(await hit.text());
}

async function observeKeys(hash, cache) {
    const keys = await cache.keys();
    hash.num(keys.length);
    hash.str(keys.map(key => path(key.url) + '|' + key.headers.get('Accept')).sort().join('\n'));
}

function cachePut(count) {
    return { async run() {
        const timer = new Timer(), hash = new Hash();
        await caches.delete('bench');
        const cache = await caches.open('bench');
        await timer.time(batch(count, 50, i => cache.put(request(i), response(i))));
        await observeKeys(hash, cache);
        return { ms: timer.ms, bytes: totalBytes(count), checksum: hash.hex() };
    } };
}

// Hits with every Vary spelling, Vary misses, ignoreVary hits and absent URLs.
function cacheMatch(count) {
    return {
        async setup() { await populate('bench', count); },
        async run() {
            const timer = new Timer(), hash = new Hash();
            const cache = await caches.open('bench');
            const results = new Array(count);
            await timer.time(batch(count, 25, async i => {
                let hit;
                switch (i % 10) {
                case 7: hit = await cache.match(request(i, 'application/x-other')); break;
                case 8: hit = await cache.match(request(i, 'application/x-other'), { ignoreVary: true }); break;
                case 9: hit = await cache.match(origin + '/absent/' + i); break;
                default: hit = await cache.match(request(i));
                }
                results[i] = hit && { status: hit.status, index: hit.headers.get('X-Index'), vary: hit.headers.get('Vary'), text: await hit.text() };
            }));
            for (const r of results) {
                if (!r) hash.str('miss'); else { hash.str(r.status); hash.str(r.index); hash.str(r.vary); hash.str(r.text); }
            }
            return { ms: timer.ms, bytes: totalBytes(count), checksum: hash.hex() };
        }
    };
}

const shapes = {
    CachePut100Vary: cachePut(100),
    CachePut10000Vary: cachePut(10000),
    CacheMatch100Vary: cacheMatch(100),
    CacheMatch10000Vary: cacheMatch(10000),

    // Run in a new network process: the cache's index is read from its record files.
    CacheOpen1000: {
        async setup() { await populate('bench', 1000); await caches.keys(); },
        async run() {
            const timer = new Timer(), hash = new Hash();
            const cache = await timer.time(caches.open('bench'));
            const keys = await timer.time(cache.keys());
            hash.num(keys.length);
            hash.str(keys.map(key => path(key.url) + '|' + key.headers.get('Accept')).sort().join('\n'));
            hash.str((await caches.keys()).join(','));
            return { ms: timer.ms, bytes: 1000 * 512, checksum: hash.hex() };
        }
    },

    // Run in a new network process: every record's file is read and decoded, bodies included.
    CacheRecordDecode1000: {
        async setup() { await populate('bench', 1000); await caches.keys(); },
        async run() {
            const timer = new Timer(), hash = new Hash();
            const cache = await caches.open('bench');
            const hits = await timer.time((async () => {
                const all = await cache.matchAll();
                return Promise.all(all.map(async hit => ({ status: hit.status, index: hit.headers.get('X-Index'), vary: hit.headers.get('Vary'), text: await hit.text() })));
            })());
            hits.sort((x, y) => Number(x.index) - Number(y.index));
            hash.num(hits.length);
            for (const h of hits) { hash.str(h.status); hash.str(h.index); hash.str(h.vary); hash.str(h.text); }
            return { ms: timer.ms, bytes: totalBytes(1000), checksum: hash.hex() };
        }
    },

    // matchAll with a request and ignoreSearch, keys with a request, and a match by string URL.
    CacheMatchAll1000: {
        async setup() { await populate('bench', 1000); },
        async run() {
            const timer = new Timer(), hash = new Hash();
            const cache = await caches.open('bench');
            const probes = [];
            await timer.time((async () => {
                for (let i = 0; i < 100; ++i) {
                    probes.push(await cache.matchAll(origin + '/r/' + (i * 9) + '?q=' + i, { ignoreSearch: true }));
                    probes.push(await cache.keys(request(i * 7), { ignoreVary: true }));
                    probes.push(await cache.match(origin + '/r/' + (i * 9)));
                }
            })());
            for (const p of probes) {
                if (Array.isArray(p)) { hash.num(p.length); for (const e of p) hash.str(path(e.url)); } else hash.str(p ? p.status : 'miss');
            }
            return { ms: timer.ms, bytes: 300 * 1024, checksum: hash.hex() };
        }
    },

    // Replacing records (put over an existing request), deleting present and absent requests, then the index.
    CacheReplaceDelete: {
        async run() {
            const timer = new Timer(), hash = new Hash();
            const cache = await populate('bench', 500);
            const deleted = [];
            await timer.time((async () => {
                await batch(500, 50, i => cache.put(request(i), response(i, 3)));
                for (let i = 0; i < 250; ++i) deleted.push(await cache.delete(request(i * 2)));
                for (let i = 0; i < 100; ++i) deleted.push(await cache.delete(origin + '/absent/' + i));
                for (let i = 0; i < 50; ++i) deleted.push(await cache.delete(request(i * 4 + 1, 'application/x-other'), { ignoreVary: true }));
            })());
            hash.str(deleted.join(','));
            await observeKeys(hash, cache);
            await observe(hash, await cache.match(request(1)));
            return { ms: timer.ms, bytes: totalBytes(500), checksum: hash.hex() };
        }
    },

    // The manager's operations: opening many caches, listing, has, deleting, matching across caches.
    CacheManagerOps: {
        async run() {
            const timer = new Timer(), hash = new Hash();
            for (const key of await caches.keys()) await caches.delete(key);
            const results = [];
            await timer.time((async () => {
                for (let i = 0; i < 100; ++i) {
                    const cache = await caches.open('c' + i);
                    if (i % 10 == 0) await cache.put(request(i), response(i));
                }
                results.push((await caches.keys()).join(','));
                for (let i = 0; i < 50; ++i) results.push(await caches.has('c' + i), await caches.has('missing' + i));
                for (let i = 0; i < 50; ++i) { const hit = await caches.match(request(i * 10)); results.push(hit ? hit.status : 'miss'); }
                for (let i = 0; i < 100; i += 2) results.push(await caches.delete('c' + i), await caches.delete('gone' + i));
                results.push((await caches.keys()).join(','));
            })());
            hash.str(results.join('|'));
            return { ms: timer.ms, bytes: 1000, checksum: hash.hex() };
        }
    },
};

// ---- Origin private file system ----
async function emptyRoot() {
    const root = await navigator.storage.getDirectory();
    const names = [];
    for await (const name of root.keys()) names.push(name);
    for (const name of names) await root.removeEntry(name, { recursive: true });
    return root;
}

async function listing(directory) {
    const entries = [];
    for await (const [name, handle] of directory.entries()) entries.push(handle.kind + ':' + name);
    return entries.sort().join(',');
}

function opfsWrite(fileSize, files, chunkSize) {
    return { async run() {
        const timer = new Timer(), hash = new Hash();
        const root = await emptyRoot();
        const errors = [];
        for (let f = 0; f < files; ++f) {
            const file = await root.getFileHandle('write' + f, { create: true });
            await timer.time((async () => {
                const writable = await file.createWritable();
                for (let at = 0; at < fileSize; at += chunkSize) {
                    const from = ((f * 4099 + at / chunkSize * 131072) % (payload.length - chunkSize + 1));
                    await writable.write(payload.subarray(from, from + chunkSize));
                }
                await writable.close();
            })());
        }
        for (let f = 0; f < files; ++f) {
            const content = new Uint8Array(await (await (await root.getFileHandle('write' + f)).getFile()).arrayBuffer());
            hash.bytes(content);
        }
        hash.str(await listing(root));
        return { ms: timer.ms, bytes: fileSize * files, checksum: hash.hex() };
    } };
}

shapes.OpfsWrite1MB = opfsWrite(1 << 20, 8, 1 << 16);
shapes.OpfsWrite64MB = opfsWrite(64 << 20, 1, 1 << 20);

// Many small commands on one writable: positioned writes, seeks, truncates; then keepExistingData.
shapes.OpfsWritableSmallOps = {
    async run() {
        const timer = new Timer(), hash = new Hash();
        const root = await emptyRoot();
        for (let f = 0; f < 10; ++f) {
            const file = await root.getFileHandle('small' + f, { create: true });
            await timer.time((async () => {
                let writable = await file.createWritable();
                for (let i = 0; i < 200; ++i) {
                    await writable.write({ type: 'write', position: i * 50, data: bodyOf(i + f, 100) });
                    if (i % 20 == 19) await writable.seek(i * 10);
                    if (i % 50 == 49) await writable.truncate(i * 40);
                }
                await writable.close();
                writable = await file.createWritable({ keepExistingData: true });
                await writable.write({ type: 'write', position: 5, data: bodyOf(f, 64) });
                await writable.truncate(4000);
                await writable.close();
            })());
            hash.str(await (await file.getFile()).text());
        }
        return { ms: timer.ms, bytes: 10 * 8000, checksum: hash.hex() };
    }
};

shapes.OpfsGetHandleNames1000 = {
    async setup() {
        const root = await emptyRoot();
        await batch(1000, 50, i => root.getFileHandle('file' + (i % 7 == 0 ? '\u00e9' : '') + i, { create: true }));
        await batch(40, 20, i => root.getDirectoryHandle('dir' + i, { create: true }));
    },
    async run() {
        const timer = new Timer(), hash = new Hash();
        const root = await navigator.storage.getDirectory();
        const names = [];
        await timer.time((async () => {
            for (let pass = 0; pass < 10; ++pass) {
                const all = [];
                for await (const name of root.keys()) all.push(name);
                names.push(all);
            }
            for (let pass = 0; pass < 2; ++pass) names.push((await listing(root)).split(','));
        })());
        for (const all of names) { hash.num(all.length); hash.str(all.slice().sort().join('\n')); }
        return { ms: timer.ms, bytes: 12 * 1040 * 8, checksum: hash.hex() };
    }
};

// Move files between directories and rename them, and move directories; the pass ends where it began.
shapes.OpfsMove = {
    async setup() {
        const root = await emptyRoot();
        const a = await root.getDirectoryHandle('a', { create: true });
        for (const name of ['b', 'c']) await root.getDirectoryHandle(name, { create: true });
        await batch(300, 50, async i => { const f = await a.getFileHandle('m' + i, { create: true }); const w = await f.createWritable(); await w.write(bodyOf(i, 64)); await w.close(); });
        await batch(10, 10, async i => { const d = await a.getDirectoryHandle('sub' + i, { create: true }); await d.getFileHandle('in' + i, { create: true }); });
    },
    async run() {
        const timer = new Timer(), hash = new Hash();
        const root = await navigator.storage.getDirectory();
        const [a, b, c] = await Promise.all(['a', 'b', 'c'].map(name => root.getDirectoryHandle(name)));
        const errors = [];
        await timer.time((async () => {
            for (let i = 0; i < 300; ++i) await (await a.getFileHandle('m' + i)).move(b, 'm' + i);
            for (let i = 0; i < 300; ++i) await (await b.getFileHandle('m' + i)).move(b, 'renamed' + i);
            for (let i = 0; i < 300; ++i) await (await b.getFileHandle('renamed' + i)).move(c, 'x' + i);
            for (let i = 0; i < 300; ++i) await (await c.getFileHandle('x' + i)).move(a, 'm' + i);
            for (let i = 0; i < 10; ++i) await (await a.getDirectoryHandle('sub' + i)).move(b, 'moved' + i);
            for (let i = 0; i < 10; ++i) await (await b.getDirectoryHandle('moved' + i)).move(a, 'sub' + i);
            // Errors: onto names that are not valid. (A file moved onto a directory's name succeeds and replaces
            // the file, so it would change what the next pass starts from.)
            for (let i = 0; i < 20; ++i) {
                errors.push((await settle((await a.getFileHandle('m' + i)).move(b, '..'))).error);
                errors.push((await settle((await a.getFileHandle('m' + i)).move(b, 'a/b'))).error);
            }
        })());
        hash.str(errors.join(','));
        for (const d of [a, b, c]) { hash.str(await listing(d)); }
        return { ms: timer.ms, bytes: 1210 * 64, checksum: hash.hex() };
    }
};

// Rejected requests: invalid names, absent entries, wrong kinds, removing a full directory without recursive.
shapes.OpfsErrorPaths = {
    async run() {
        const timer = new Timer(), hash = new Hash();
        const root = await emptyRoot();
        const dir = await root.getDirectoryHandle('full', { create: true });
        await dir.getFileHandle('inside', { create: true });
        await root.getFileHandle('plain', { create: true });
        const names = ['', '.', '..', 'a/b', 'a\u0000b', '..\u0000x', 'a\\b', '\ud800', 'x'.repeat(1000), 'Plain', 'e\u0301', '\u00e9'];
        const results = [];
        await timer.time((async () => {
            for (let round = 0; round < 25; ++round) {
                for (const name of names) {
                    results.push((await settle(root.getFileHandle(name, { create: true }))).error);
                    results.push((await settle(root.getDirectoryHandle(name, { create: round % 2 == 0 }))).error);
                    results.push((await settle(root.removeEntry(name))).error);
                }
                results.push((await settle(root.getFileHandle('absent' + round))).error);
                results.push((await settle(root.getDirectoryHandle('plain'))).error);
                results.push((await settle(root.getFileHandle('full'))).error);
                results.push((await settle(root.removeEntry('full'))).error);
                results.push((await settle(root.removeEntry('absent'))).error);
            }
        })());
        hash.str(results.join(','));
        hash.str(await listing(root));
        return { ms: timer.ms, bytes: 25 * (names.length * 3 + 5) * 32, checksum: hash.hex() };
    }
};

// Creating nested directories, resolve, isSameEntry, then removing the tree recursively.
shapes.OpfsTreeOps = {
    async run() {
        const timer = new Timer(), hash = new Hash();
        const root = await emptyRoot();
        const results = [];
        await timer.time((async () => {
            let dir = root;
            const chain = [];
            for (let depth = 0; depth < 30; ++depth) {
                dir = await dir.getDirectoryHandle('d' + depth, { create: true });
                chain.push(dir);
                for (let f = 0; f < 5; ++f) await dir.getFileHandle('f' + f, { create: true });
            }
            for (let depth = 0; depth < 30; depth += 3) {
                const leaf = await chain[depth].getFileHandle('f1');
                results.push((await root.resolve(leaf)).join('/'));
                results.push(await leaf.isSameEntry(await chain[depth].getFileHandle('f1')));
                results.push(await leaf.isSameEntry(await chain[depth].getFileHandle('f2')));
                results.push((await settle(chain[depth].resolve(root))).value === null);
            }
            await root.removeEntry('d0', { recursive: true });
            results.push(await listing(root));
        })());
        hash.str(results.join('|'));
        return { ms: timer.ms, bytes: 30 * 5 * 64, checksum: hash.hex() };
    }
};

// Sync access handles (worker only): open, size, truncate, write, flush, close, with the capacity checks.
shapes.OpfsSyncAccessHandle = {
    async run() {
        await emptyRoot();
        const worker = new Worker('/worker.js');
        const result = await new Promise((resolve, reject) => { worker.onmessage = e => resolve(e.data); worker.onerror = e => reject(new Error(e.message)); });
        worker.terminate();
        return result;
    }
};

// ---- Quota ----
// Estimates with data in both stores, persisted(), and writes past a small per-origin quota.
shapes.StorageQuotaEstimate = {
    async setup() {
        await populate('bench', 200);
        const root = await emptyRoot();
        await batch(20, 10, async i => { const f = await root.getFileHandle('q' + i, { create: true }); const w = await f.createWritable(); await w.write(payload.subarray(0, 65536)); await w.close(); });
    },
    async run() {
        const timer = new Timer(), hash = new Hash();
        const estimates = [];
        await timer.time((async () => {
            for (let i = 0; i < 300; ++i) estimates.push(await navigator.storage.estimate());
            for (let i = 0; i < 100; ++i) estimates.push(await navigator.storage.persisted());
        })());
        const usages = estimates.filter(e => typeof e == 'object');
        hash.str(usages.every(e => e.usage > 0 && e.quota > e.usage && e.usage == usages[0].usage));
        hash.str(estimates.filter(e => typeof e == 'boolean').join(','));
        return { ms: timer.ms, bytes: 400 * 32, checksum: hash.hex() };
    }
};

shapes.StorageQuotaExceeded = {
    async run() {
        const timer = new Timer(), hash = new Hash();
        const root = await emptyRoot();
        await caches.delete('bench');
        const cache = await caches.open('bench');
        const results = [];
        await timer.time((async () => {
            for (let i = 0; i < 12; ++i) {
                const f = await root.getFileHandle('big' + i, { create: true });
                results.push((await settle((async () => { const w = await f.createWritable(); await w.write(payload); await w.close(); })())).error || 'ok');
            }
            for (let i = 0; i < 40; ++i)
                results.push((await settle(cache.put(request(i), new Response(bodyOf(i, 200000))))).error || 'ok');
            for (let i = 0; i < 12; ++i) results.push((await settle(root.removeEntry('big' + i))).error || 'ok');
        })());
        // Which writes the quota refuses depends on its rounding; the digest holds the count of each outcome, and
        // the note shows the sequence to a person.
        const counts = {};
        for (const r of results) counts[r] = (counts[r] || 0) + 1;
        hash.str(JSON.stringify(counts));
        hash.str(results.join(','));
        return { ms: timer.ms, bytes: 12 * payload.length + 40 * 200000, checksum: hash.hex(), note: JSON.stringify(counts) };
    }
};

// Three thousand puts at once past a 64 KB per-origin quota: once one is refused, the rest queue behind its quota check.
shapes.StorageQuotaQueued = {
    async run() {
        const timer = new Timer(), hash = new Hash();
        await caches.delete('bench');
        const cache = await caches.open('bench');
        const count = 3000;
        const results = [];
        await timer.time(Promise.all(Array.from({ length: count }, async (_, i) => { results[i] = (await settle(cache.put(request(i), new Response(bodyOf(i, 1000))))).error || 'ok'; })));
        // Which puts the quota refuses depends on the order they arrive in; the digest holds what does not.
        const stored = new Set((await cache.keys()).map(r => path(r.url)));
        hash.str(results.every((r, i) => (r == 'ok') == stored.has('/r/' + i)));
        hash.str(Array.from(new Set(results)).sort().join(','));
        hash.num(count);
        const accepted = results.filter(r => r == 'ok').length;
        return { ms: timer.ms, bytes: count * 1000, checksum: hash.hex(), note: accepted + ' stored, ' + (count - accepted) + ' refused' };
    }
};

// ---- Background Fetch's store ----
shapes.BackgroundFetchStore = {
    async setup() {
        await navigator.serviceWorker.register('/sw.js');
        const registration = await navigator.serviceWorker.ready;
        while (registration.active.state != 'activated')
            await new Promise(resolve => setTimeout(resolve, 10));
    },
    async run(pass) {
        const timer = new Timer(), hash = new Hash();
        const registration = await navigator.serviceWorker.ready;
        const urls = ['/bf/0', '/bf/1', '/bf/2', '/bf/3'];
        const outcomes = [];
        const settled = fetch => new Promise(resolve => {
            const done = () => { if (fetch.result) resolve(fetch.result + ':' + fetch.failureReason); };
            fetch.addEventListener('progress', done);
            done();
            setTimeout(() => resolve('timeout'), 20000);
        });
        const prefix = 'p' + pass + '-';
        await timer.time((async () => {
            for (let k = 0; k < 8; ++k) {
                const fetch = await registration.backgroundFetch.fetch(prefix + k, urls);
                outcomes.push(await settled(fetch));
            }
            const ids = (await registration.backgroundFetch.getIds()).filter(id => id.startsWith(prefix)).sort();
            outcomes.push(ids.join(','));
            for (let k = 0; k < 8; ++k) {
                const fetch = await registration.backgroundFetch.get(prefix + k);
                if (!fetch) { outcomes.push('gone'); continue; }
                outcomes.push(fetch.downloaded + '/' + fetch.downloadTotal + '/' + fetch.recordsAvailable);
                const records = await fetch.matchAll();
                for (const record of records) outcomes.push(path(record.request.url));
            }
        })());
        hash.str(outcomes.join('|'));
        return { ms: timer.ms, bytes: 8 * 4 * 1024, checksum: hash.hex() };
    }
};

return {
    shapes,
    async setup(name) { const shape = shapes[name]; if (shape.setup) await shape.setup(); },
    async run(name, pass) { return await shapes[name].run(pass); },
};
})();
)BENCH"_s;

static constexpr auto serviceWorkerScript = R"BENCH(
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(clients.claim()));
)BENCH"_s;

static constexpr auto workerScript = R"BENCH(
class Hash {
    constructor() { this.a = 0x811c9dc5; this.b = 0x9747b28c; }
    byte(x) { this.a = Math.imul(this.a ^ x, 16777619) >>> 0; this.b = (Math.imul(this.b, 31) + x + 1) >>> 0; }
    str(s) { s = String(s); this.byte(s.length & 255); for (let i = 0; i < s.length; ++i) this.byte(s.charCodeAt(i) & 255); }
    bytes(u8) { for (let i = 0; i < u8.length; ++i) this.byte(u8[i]); }
    hex() { return this.a.toString(16).padStart(8, '0') + this.b.toString(16).padStart(8, '0'); }
}

(async () => {
    try {
        const hash = new Hash();
        let ms = 0;
        const root = await navigator.storage.getDirectory();
        const buffer = new Uint8Array(65536);
        for (let i = 0; i < buffer.length; ++i) buffer[i] = (i * 31 + 7) & 255;
        const errors = [];
        for (let f = 0; f < 40; ++f) {
            const file = await root.getFileHandle('sync' + f, { create: true });
            const start = performance.now();
            const handle = await file.createSyncAccessHandle();
            hash.str(handle.getSize());
            handle.truncate(1 << 20);
            for (let at = 0; at < (1 << 20); at += buffer.length) handle.write(buffer, { at });
            handle.flush();
            handle.truncate(1 << 19);
            hash.str(handle.getSize());
            ms += performance.now() - start;
            const back = new Uint8Array(4096);
            handle.read(back, { at: 8192 });
            hash.bytes(back);
            const second = performance.now();
            // A second handle on the same file is refused while the first is open.
            try { await file.createSyncAccessHandle(); errors.push('opened'); } catch (e) { errors.push(e.name); }
            handle.close();
            ms += performance.now() - second;
        }
        hash.str(errors.join(','));
        postMessage({ ms, bytes: 40 * (1 << 20), checksum: hash.hex() });
    } catch (e) {
        postMessage({ ms: 0, bytes: 0, checksum: 'error:' + e.name + ':' + e.message });
    }
})();
)BENCH"_s;

// Fixed bodies for Background Fetch's four URLs.
static constexpr auto backgroundFetchBody = "background fetch response body, repeated: abcdefghijklmnopqrstuvwxyz0123456789 abcdefghijklmnopqrstuvwxyz0123456789"_s;

} // namespace TestWebKitAPI::OriginStorageBenchInputs
