self.addEventListener("fetch", (event) => {
    if (!event.request.url.includes("stream-never-closes"))
        return;

    // The body gets one chunk and is never closed, so the fetch is still ongoing when the worker is terminated.
    const stream = new ReadableStream({
        start(controller) {
            controller.enqueue(new TextEncoder().encode("first chunk"));
        }
    });
    event.respondWith(new Response(stream, { headers: { "Content-Type": "text/plain" } }));
});
