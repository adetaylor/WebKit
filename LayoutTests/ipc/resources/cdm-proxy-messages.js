function log(line)
{
    document.getElementById('log').textContent += line + '\n';
}

const string = value => ({ type: 'String', value });
const uint8 = value => ({ type: 'uint8_t', value });
const uint64 = value => ({ type: 'uint64_t', value });
const bool = value => ({ type: 'bool', value: value ? 1 : 0 });
const vector = elements => ({ type: 'Vector', value: elements });

// A Ref<SharedBuffer>, encoded as the C++ coder encodes one under 4096 bytes: inline segments.
function buffer(text)
{
    const bytes = Array.from(new TextEncoder().encode(text));
    return [uint8(1), vector(bytes.length ? [[uint64(bytes.length), ...bytes.map(uint8)]] : [])];
}

// A Ref<SharedBuffer> in shared memory, as the C++ coder encodes one of 4096 bytes or more.
function sharedMemoryBuffer(size, character)
{
    const memory = IPC.createSharedMemory(size);
    memory.writeBytes(new Uint8Array(size).fill(character.charCodeAt(0)));
    return [uint8(0), bool(true), { type: 'SharedMemory', value: memory, protection: 'ReadOnly' }];
}

function optionalBuffer(text)
{
    return text === null ? [bool(false)] : [bool(true), ...buffer(text)];
}

function capability(contentType, robustness, encryptionScheme)
{
    return [string(contentType), string(robustness), ...(encryptionScheme === undefined ? [bool(false)] : [bool(true), bool(encryptionScheme)])];
}

// A CDMKeySystemConfiguration: label, init data types, audio and video capabilities, distinctive
// identifier and persistent state requirements, session types.
function configuration({ label = '', initDataTypes = [], audio = [], video = [], distinctiveIdentifier = 1, persistentState = 1, sessionTypes = [] })
{
    return [
        string(label),
        vector(initDataTypes.map(type => [string(type)])),
        vector(audio.map(c => capability(...c))),
        vector(video.map(c => capability(...c))),
        uint8(distinctiveIdentifier),
        uint8(persistentState),
        vector(sessionTypes.map(type => [uint8(type)])),
    ];
}

// Identifiers carry their process's domain in their top bits, so differ from run to run; they print as
// "ID". A reply's destination, after the message name, is the ID of the message it replies to.
function isIdentifier(value)
{
    return (value >> 60n) && !(value & 0x0fffffffff000000n);
}

function hex(result)
{
    if (!result?.buffer)
        return 'not handled';
    const view = new DataView(result.buffer);
    const words = [];
    for (let offset = 0; offset < view.byteLength; offset += 8) {
        // The message name, which changes as messages are added, and the identifier of the reply.
        if (offset < 16) {
            words.push(offset ? 'REPLY-TO' : 'HEADER');
            continue;
        }
        if (offset + 8 <= view.byteLength && isIdentifier(view.getBigUint64(offset, true))) {
            words.push('ID');
            continue;
        }
        let word = '';
        for (let i = offset; i < Math.min(offset + 8, view.byteLength); ++i)
            word += view.getUint8(i).toString(16).padStart(2, '0');
        words.push(word);
    }
    return words.join(' ');
}

// The exact identifier in a reply, whose argument JavaScript only has as an approximate Number.
function identifierIn(result)
{
    const approximation = result?.arguments?.[0]?.value;
    if (typeof approximation !== 'number')
        return null;
    const view = new DataView(result.buffer);
    for (let offset = 0; offset + 8 <= view.byteLength; ++offset) {
        const value = view.getBigUint64(offset, true);
        if (isIdentifier(value) && Number(value) === approximation)
            return value;
    }
    return null;
}

function sendSync(name, destination, args)
{
    try {
        return IPC.sendSyncMessage('GPU', destination, IPC.messages[name].name, 1000, args);
    } catch (error) {
        return null;
    }
}

function sendWithReply(name, destination, args)
{
    return new Promise(resolve => {
        const timeout = setTimeout(() => resolve(null), 1000);
        IPC.connectionForProcessTarget('GPU').sendWithAsyncReply(destination, IPC.messages[name].name, args, result => {
            clearTimeout(timeout);
            resolve(result?.arguments ? result : null);
        });
    });
}

function send(name, destination, args)
{
    IPC.sendMessage('GPU', destination, IPC.messages[name].name, args);
}

function logSync(name, destination, args)
{
    const result = sendSync(name, destination, args);
    log(`${name}: ${hex(result)}`);
    return result;
}

async function logWithReply(name, destination, args)
{
    const result = await sendWithReply(name, destination, args);
    log(`${name}: ${hex(result)}`);
    return result;
}

function base64url(text)
{
    return btoa(text).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}
