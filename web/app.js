const form = document.querySelector("#download-form");
const input = document.querySelector("#playlist-url");
const jobsEl = document.querySelector("#jobs");
const messageEl = document.querySelector("#form-message");
const refreshBtn = document.querySelector("#refresh-jobs");
const template = document.querySelector("#job-template");
const logModal = document.querySelector("#log-modal");
const modalTitle = document.querySelector("#modal-title");
const modalSummary = document.querySelector("#modal-summary");
const modalLog = document.querySelector("#modal-log");
const closeLogModal = document.querySelector("#close-log-modal");

const activeLogs = new Map();
const jobElements = new Map();
const jobStateCache = new Map();
const deletingJobs = new Set();
let lastJobsSignature = "";

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  const data = await response.json();
  if (!response.ok) {
    throw new Error(data.error || "Request failed");
  }
  return data;
}

function setMessage(text, type = "") {
  messageEl.textContent = text;
  messageEl.className = `message ${type}`.trim();
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function formatJobTitle(job) {
  return job.playlistName || "Playlist job";
}

function formatFolder(job) {
  if (!job.outputFolder) return null;
  const parts = job.outputFolder.split("\\");
  return parts[parts.length - 1];
}

function formatPhase(phase) {
  if (phase === "Queued") return "Ready to download";
  return phase || "-";
}

function formatMeta(job) {
  const lines = [];
  lines.push(`Stage: ${formatPhase(job.phase)}`);
  if (job.trackCount) lines.push(`Tracks found: ${job.trackCount}`);
  if (job.uniqueTrackCount) lines.push(`Unique tracks: ${job.uniqueTrackCount}`);
  lines.push(`Downloaded files: ${job.downloadedCount || 0}`);
  if (job.missingCount !== null && job.missingCount !== undefined) {
    lines.push(`Files left: ${job.missingCount}`);
  }
  const folder = formatFolder(job);
  if (folder) lines.push(`Saved in: downloads\\${folder}`);
  if (job.error) lines.push(`Problem: ${job.error}`);
  return lines.map(line => `<span>${escapeHtml(line)}</span>`).join("");
}

function getLogLines(logText) {
  return (logText || "")
    .split(/\r?\n/)
    .map(line => line.trimEnd())
    .filter(Boolean);
}

function formatTimestamp(line) {
  const match = line.match(/^\[(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\]\s*(.*)$/);
  if (!match) return line;

  const [, year, month, day, hourText, minute, second, rest] = match;
  let hour = Number(hourText);
  const suffix = hour >= 12 ? "PM" : "AM";
  hour %= 12;
  if (hour === 0) hour = 12;
  return `[${month}/${day}/${year} ${hour}:${minute}:${second} ${suffix}] ${rest}`;
}

function humanizeLine(line) {
  if (!line) return "Waiting for activity.";

  const formatted = formatTimestamp(line);
  const bare = formatted.replace(/^\[[^\]]+\]\s*/, "");

  if (bare.startsWith("Running: spotdl.exe save")) return formatted.replace(bare, "Reading playlist details from Spotify.");
  if (bare.startsWith("Running: spotdl.exe download")) return formatted.replace(bare, "Starting the download pass.");
  if (bare.startsWith("Processing query:")) return formatted.replace(bare, "Looking up the playlist link.");
  if (/^Found \d+ songs in /.test(bare)) {
    const count = bare.match(/^Found (\d+) songs/)?.[1] || "";
    return formatted.replace(bare, `Playlist found. ${count} songs detected.`);
  }
  if (bare.startsWith("Downloaded \"")) {
    const name = bare.match(/^Downloaded "(.+?)"/)?.[1];
    return formatted.replace(bare, name ? `Downloaded: ${name}` : "A track finished downloading.");
  }
  if (bare.startsWith("Retrying missing song:")) return formatted.replace(bare, bare);
  if (bare.startsWith("Save step failed. Retrying metadata fetch")) return formatted.replace(bare, "Retrying the Spotify metadata lookup.");
  if (bare.includes("You might be blocked by YouTube Music")) return formatted.replace(bare, "The audio provider may be rate-limiting requests. Fallbacks can still recover songs.");
  if (bare.startsWith("Canceled by user.")) return formatted.replace(bare, "Canceled from the app.");
  if (bare.startsWith("Worker failed: --- Logging error ---")) return formatted.replace(bare, "The provider emitted a logging error. The downloader will try safer fallbacks where possible.");
  if (bare.startsWith("Worker failed:")) return formatted.replace(bare, bare.replace("Worker failed:", "The downloader stopped:"));
  if (bare.startsWith("--- Logging error ---")) return formatted.replace(bare, "The provider emitted a logging error. Fallbacks may still continue.");
  if (bare.startsWith("Finished. Downloaded files:")) {
    return formatted.replace(
      bare,
      bare
        .replace("Finished. Downloaded files:", "Finished. Files downloaded:")
        .replace("Missing songs:", "Files left:")
    );
  }

  return formatted;
}

function getLatestLogPreview(logText) {
  const lines = getLogLines(logText).slice(-4);
  if (lines.length === 0) return "No log output yet.";
  return lines.map(humanizeLine).join("\n");
}

function getLatestHumanLine(logText) {
  const lines = getLogLines(logText);
  const latest = lines.length ? lines[lines.length - 1] : "";
  return humanizeLine(latest);
}

async function loadLog(jobId, force = false) {
  if (!force && activeLogs.has(jobId)) {
    return activeLogs.get(jobId);
  }

  const data = await fetchJson(`/api/jobs/${jobId}/log`);
  const nextLog = data.log || "";
  activeLogs.set(jobId, nextLog);
  return nextLog;
}

function renderMissingSongs(job, listEl) {
  listEl.innerHTML = "";
  if (!job.missingSongs || job.missingSongs.length === 0) {
    const li = document.createElement("li");
    li.textContent = "None";
    listEl.appendChild(li);
    return;
  }

  for (const song of job.missingSongs) {
    const li = document.createElement("li");
    li.textContent = `${song.artist} - ${song.title}`;
    listEl.appendChild(li);
  }
}

function openLogModal(job, rawLog) {
  modalTitle.textContent = formatJobTitle(job);
  modalSummary.textContent = getLatestHumanLine(rawLog);
  modalLog.textContent = getLogLines(rawLog).map(humanizeLine).join("\n") || "No log output yet.";
  logModal.showModal();
}

async function removeJob(job) {
  deletingJobs.add(job.id);
  const card = jobElements.get(job.id);
  if (card) {
    card.remove();
    jobElements.delete(job.id);
  }

  await fetchJson(`/api/jobs/${job.id}`, { method: "DELETE" });
  activeLogs.delete(job.id);
  jobStateCache.delete(job.id);
  deletingJobs.delete(job.id);
  lastJobsSignature = "";
  setMessage(`Removed saved history for "${formatJobTitle(job)}".`, "success");

  if (!jobsEl.children.length) {
    jobsEl.innerHTML = '<p class="empty">No saved jobs yet.</p>';
  }
}

async function cancelJob(job) {
  await fetchJson(`/api/jobs/${job.id}/cancel`, { method: "POST" });
  activeLogs.delete(job.id);
  jobStateCache.delete(job.id);
  lastJobsSignature = "";
  setMessage(`Canceled "${formatJobTitle(job)}".`, "success");
  await renderJobs();
}

async function openFolder(job) {
  await fetchJson(`/api/jobs/${job.id}/open-folder`, { method: "POST" });
}

function ensureJobCard(job) {
  if (jobElements.has(job.id)) {
    return jobElements.get(job.id);
  }

  const fragment = template.content.cloneNode(true);
  const card = fragment.querySelector(".job");
  const refs = {
    titleEl: fragment.querySelector(".job-title"),
    urlEl: fragment.querySelector(".job-url"),
    badgeEl: fragment.querySelector(".badge"),
    metaEl: fragment.querySelector(".meta"),
    missingEl: fragment.querySelector(".missing-list"),
    previewEl: fragment.querySelector(".log-preview"),
    openFolderButtonEl: fragment.querySelector(".open-folder-button"),
    cancelButtonEl: fragment.querySelector(".cancel-button"),
    logButtonEl: fragment.querySelector(".log-button"),
    removeButtonEl: fragment.querySelector(".remove-button"),
  };

  card._refs = refs;
  jobElements.set(job.id, card);
  return card;
}

async function upsertJob(job) {
  if (deletingJobs.has(job.id)) return;

  jobsEl.querySelector(".empty")?.remove();
  const card = ensureJobCard(job);
  const {
    titleEl,
    urlEl,
    badgeEl,
    metaEl,
    missingEl,
    previewEl,
    openFolderButtonEl,
    cancelButtonEl,
    logButtonEl,
    removeButtonEl,
  } = card._refs;

  const previousState = jobStateCache.get(job.id);
  const shouldReloadLog = !previousState || previousState.updatedAt !== job.updatedAt || previousState.status !== job.status;
  const rawLog = await loadLog(job.id, shouldReloadLog).catch(error => `Unable to load log: ${error.message}`);

  card.dataset.status = job.status;
  titleEl.textContent = formatJobTitle(job);
  urlEl.textContent = job.url;
  badgeEl.textContent = job.status;
  metaEl.innerHTML = formatMeta(job);
  renderMissingSongs(job, missingEl);
  previewEl.textContent = getLatestLogPreview(rawLog);
  previewEl.dataset.error = job.error ? "true" : "false";

  openFolderButtonEl.disabled = !job.outputFolder;
  cancelButtonEl.disabled = !(job.status === "running" || job.status === "queued");
  removeButtonEl.disabled = job.status === "running" || job.status === "queued";

  openFolderButtonEl.onclick = () => {
    openFolder(job).catch(error => setMessage(error.message, "error"));
  };
  cancelButtonEl.onclick = () => {
    cancelJob(job).catch(error => setMessage(error.message, "error"));
  };
  logButtonEl.onclick = () => openLogModal(job, rawLog);
  removeButtonEl.onclick = () => {
    removeJob(job).catch(error => setMessage(error.message, "error"));
  };

  jobStateCache.set(job.id, {
    updatedAt: job.updatedAt,
    status: job.status,
  });

  if (!card.isConnected) {
    jobsEl.appendChild(card);
  }
}

async function renderJobs() {
  const data = await fetchJson("/api/jobs");
  const jobs = (data.jobs || []).filter(job => !deletingJobs.has(job.id));

  const signature = JSON.stringify(
    jobs.map(job => ({
      id: job.id,
      status: job.status,
      phase: job.phase,
      downloadedCount: job.downloadedCount,
      missingCount: job.missingCount,
      updatedAt: job.updatedAt,
      error: job.error,
    }))
  );

  if (signature === lastJobsSignature && jobs.length === jobElements.size) {
    return;
  }

  lastJobsSignature = signature;
  const liveIds = new Set(jobs.map(job => job.id));

  for (const [jobId, card] of jobElements.entries()) {
    if (!liveIds.has(jobId)) {
      card.remove();
      jobElements.delete(jobId);
      activeLogs.delete(jobId);
      jobStateCache.delete(jobId);
    }
  }

  for (const job of jobs) {
    await upsertJob(job);
  }

  if (jobs.length === 0 && !jobsEl.querySelector(".empty")) {
    jobsEl.innerHTML = '<p class="empty">No saved jobs yet.</p>';
  }
}

form.addEventListener("submit", async event => {
  event.preventDefault();
  const url = input.value.trim();
  if (!url) return;

  const button = form.querySelector("button[type='submit']");
  button.disabled = true;
  setMessage("Starting your playlist job...", "");

  try {
    const job = await fetchJson("/api/downloads", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url }),
    });
    activeLogs.delete(job.id);
    jobStateCache.delete(job.id);
    lastJobsSignature = "";
    input.value = "";
    setMessage("Job started. We'll keep updating the status below.", "success");
    await renderJobs();
  } catch (error) {
    setMessage(error.message, "error");
  } finally {
    button.disabled = false;
  }
});

refreshBtn.addEventListener("click", () => {
  lastJobsSignature = "";
  renderJobs().catch(error => setMessage(error.message, "error"));
});

closeLogModal.addEventListener("click", () => {
  logModal.close();
});

logModal.addEventListener("click", event => {
  const bounds = logModal.querySelector(".modal-card").getBoundingClientRect();
  const inside =
    event.clientX >= bounds.left &&
    event.clientX <= bounds.right &&
    event.clientY >= bounds.top &&
    event.clientY <= bounds.bottom;

  if (!inside) {
    logModal.close();
  }
});

renderJobs().catch(error => setMessage(error.message, "error"));
setInterval(() => {
  renderJobs().catch(() => {});
}, 1000);
