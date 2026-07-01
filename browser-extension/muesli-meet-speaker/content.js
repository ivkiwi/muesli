const MUESLI_BRIDGE_URL = "http://127.0.0.1:1477/v1/meet-speaker";
const MIN_SEND_INTERVAL_MS = 900;
const PARTICIPANT_REFRESH_INTERVAL_MS = 8000;

let lastSpeaker = "";
let lastSentAt = 0;
let lastParticipantSignature = "";
let lastParticipantSentAt = 0;

function isVisible(element) {
  const rect = element.getBoundingClientRect();
  const style = window.getComputedStyle(element);
  return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
}

function cleanName(value) {
  return value
    .replace(/\s+/g, " ")
    .replace(/\b(is speaking|speaking|is presenting|presenting|microphone is on|microphone is off|muted|unmuted)\b/gi, "")
    .replace(/[,:;-]+$/g, "")
    .trim();
}

function nameFromSpeakingLabel(label) {
  const text = cleanName(label);
  if (!/\b(speaking|is speaking)\b/i.test(label)) return "";
  if (!text || text.length < 2 || text.length > 80) return "";
  if (/^(you|your presentation|presentation)$/i.test(text)) return "";
  return text;
}

function cleanParticipantName(value) {
  return cleanName(value)
    .replace(/\s*\((you|me)\)\s*/gi, " ")
    .replace(/\b(you|me)\b$/i, "")
    .replace(/\b(tiles?|participants?|people|camera|video|microphone|captions?|pin|unpin|more options)\b/gi, "")
    .replace(/\b(ask to unmute|remove from call|joined|left)\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

function validParticipantName(name) {
  if (!name || name.length < 2 || name.length > 80) return false;
  if (/^(you|me|everyone|people|chat|activities|host controls|present now|settings|leave call)$/i.test(name)) return false;
  if (/^(muted|unmuted|speaking|presenting|camera off|microphone off)$/i.test(name)) return false;
  return /[A-Za-zА-Яа-яЁё0-9]/.test(name);
}

function addParticipant(map, rawValue) {
  const raw = (rawValue || "").trim();
  const isSelf = /\b(you|me)\b/i.test(raw);
  const name = cleanParticipantName(raw);
  if (!validParticipantName(name)) return;
  const key = name.toLocaleLowerCase();
  if (!map.has(key)) {
    map.set(key, { name, isSelf });
  } else if (isSelf) {
    map.get(key).isSelf = true;
  }
}

function collectParticipants() {
  const participants = new Map();
  const labelled = [...document.querySelectorAll("[aria-label]")].filter(isVisible);
  for (const element of labelled) {
    const label = element.getAttribute("aria-label") || "";
    if (!/\b(speaking|muted|unmuted|presenting|camera|video|microphone|participant|tile)\b/i.test(label)) continue;
    addParticipant(participants, label);
  }

  const listItems = [...document.querySelectorAll('[role="listitem"], [role="gridcell"]')].filter(isVisible);
  for (const item of listItems) {
    const firstLine = (item.innerText || item.textContent || "")
      .split("\n")
      .map((line) => line.trim())
      .find(Boolean);
    if (firstLine) addParticipant(participants, firstLine);
  }

  return [...participants.values()].sort((lhs, rhs) => lhs.name.localeCompare(rhs.name));
}

function activeSpeakerFromAriaLabels() {
  const labelled = [...document.querySelectorAll("[aria-label]")].filter(isVisible);
  for (const element of labelled) {
    const name = nameFromSpeakingLabel(element.getAttribute("aria-label") || "");
    if (name) return name;
  }
  return "";
}

function activeSpeakerFromLiveRegions() {
  const regions = [...document.querySelectorAll('[aria-live], [role="status"], [role="log"]')].filter(isVisible);
  for (const region of regions) {
    const lines = (region.innerText || region.textContent || "")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    for (const line of lines) {
      const name = nameFromSpeakingLabel(line);
      if (name) return name;
    }
  }
  return "";
}

function activeSpeakerFromCaptions() {
  const regions = [...document.querySelectorAll('[aria-live], [role="log"], [jscontroller]')].filter(isVisible);
  for (const region of regions) {
    const lines = (region.innerText || "")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    if (lines.length < 2) continue;
    const possibleName = cleanName(lines[0]);
    if (possibleName.length >= 2 && possibleName.length <= 80 && !/[.!?]$/.test(possibleName)) {
      return possibleName;
    }
  }
  return "";
}

function detectActiveSpeaker() {
  return activeSpeakerFromAriaLabels()
    || activeSpeakerFromLiveRegions()
    || activeSpeakerFromCaptions();
}

async function sendObservation(name) {
  const now = Date.now();
  const participants = collectParticipants();
  const participantSignature = participants.map((participant) => `${participant.name}|${participant.isSelf}`).join("\n");
  const shouldSendSpeaker = name && (name !== lastSpeaker || now - lastSentAt >= MIN_SEND_INTERVAL_MS);
  const shouldSendParticipants = participants.length > 0
    && (participantSignature !== lastParticipantSignature || now - lastParticipantSentAt >= PARTICIPANT_REFRESH_INTERVAL_MS);
  if (!shouldSendSpeaker && !shouldSendParticipants) return;

  if (shouldSendSpeaker) {
    lastSpeaker = name;
    lastSentAt = now;
  }
  if (shouldSendParticipants) {
    lastParticipantSignature = participantSignature;
    lastParticipantSentAt = now;
  }

  const body = {
    meetingURL: location.href,
    participants,
    source: "google-meet-extension"
  };
  if (name) body.speakerName = name;

  try {
    await fetch(MUESLI_BRIDGE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
  } catch (_) {
    // Local app may be closed. Stay quiet inside Meet.
  }
}

function sample() {
  sendObservation(detectActiveSpeaker());
}

const observer = new MutationObserver(sample);
observer.observe(document.documentElement, {
  subtree: true,
  childList: true,
  characterData: true,
  attributes: true,
  attributeFilter: ["aria-label", "class", "data-is-speaking", "data-speaking"]
});

setInterval(sample, 1500);
sample();
