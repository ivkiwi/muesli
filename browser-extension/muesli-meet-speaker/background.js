const MUESLI_BRIDGE_URL = "http://127.0.0.1:1477/v1/meet-speaker";

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "muesli.postBridgePayload") return false;

  postBridgePayload(message.payload)
    .then((status) => sendResponse({ ok: true, status }))
    .catch((error) => sendResponse({ ok: false, error: error.message }));
  return true;
});

async function postBridgePayload(payload) {
  const response = await fetch(MUESLI_BRIDGE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (!response.ok) {
    throw new Error(`Guesli bridge returned ${response.status}`);
  }
  return response.status;
}
