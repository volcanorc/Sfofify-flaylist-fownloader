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

async function startJob(url, retryOf = null) {
  const job = await fetchJson("/api/downloads", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url, retryOf }),
  });
  activeLogs.delete(job.id);
  jobStateCache.delete(job.id);
  lastJobsSignature = "";
  return job;
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
  if (job.playlistName) return job.playlistName;
  if (job.status === "queued" || job.status === "running") {
    return "Analyzing playlist";
  }
  return "Playlist job";
}

function isRetryable(job) {
  return job.status === "failed" || job.status === "canceled";
}

function isCompactJob(job) {
  return job.status === "completed" || job.status === "canceled" || job.status === "failed";
}

function getCompactSummary(job) {
  const title = formatJobTitle(job);
  if (job.status === "completed") {
    const total = job.uniqueTrackCount || job.trackCount || job.downloadedCount || 0;
    return {
      title,
      status: "completed",
      detail: `Downloaded files ${job.downloadedCount || 0}/${total}`,
    };
  }
  if (job.status === "canceled") {
    return {
      title,
      status: "canceled",
      detail: "Canceled",
    };
  }
  if (job.status === "failed") {
    return {
      title,
      status: "failed",
      detail: "Failed",
    };
  }
  return {
    title,
    status: "",
    detail: "",
  };
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

function getMatchingNote(job) {
  const total = job.uniqueTrackCount || job.trackCount || 0;
  const position = Math.min((job.matchCount || 0) + 1, total || 1);

  if (job.currentSong && total > 0) {
    return `Matching song ${position} of ${total}: ${job.currentSong}`;
  }
  if (job.currentProviderPhase) {
    return job.currentProviderPhase;
  }
  if (total > 0) {
    return `Playlist found with ${total} songs. Matching tracks to working audio sources.`;
  }
  return "Preparing the playlist for download.";
}

function hasRetryEvidence(job, rawLog) {
  return job.phase === "Retrying missing songs" || /Retrying missing song:/.test(rawLog || "");
}

function getProgressModel(job, rawLog) {
  const steps = [
    { key: "queued", label: "Received your playlist link" },
    { key: "metadata", label: "Reading playlist details" },
    { key: "matching", label: "Matching songs to audio sources" },
    { key: "downloading", label: "Downloading and organizing files" },
    { key: "retrying", label: "Retrying anything missing" },
    { key: "done", label: "Finished" },
  ];

  let activeKey = "queued";
  let note = "Your playlist is in line and ready to start.";

  if (job.status === "failed") {
    activeKey = "retrying";
    note = "The downloader hit a problem. Check the latest activity or full log below.";
  } else if (job.status === "canceled") {
    activeKey = "retrying";
    note = "This playlist was canceled from the app.";
  } else if (job.phase === "Saving playlist metadata") {
    activeKey = "metadata";
    note = "We are checking the playlist link and collecting song details from Spotify.";
  } else if (job.phase === "Preparing download queue") {
    activeKey = "matching";
    note = job.currentProviderPhase || "Preparing the saved playlist for matching.";
  } else if (job.phase === "Matching songs to sources") {
    activeKey = "matching";
    note = getMatchingNote(job);
  } else if (job.phase === "Downloading files") {
    activeKey = "downloading";
    if (job.downloadedCount > 0) {
      note = `Downloading is in progress. ${job.downloadedCount} file${job.downloadedCount === 1 ? "" : "s"} saved so far.`;
    } else {
      note = job.currentProviderPhase || "Starting the first download pass.";
    }
  } else if (job.phase === "Retrying missing songs") {
    activeKey = "retrying";
    if (job.currentSong && job.missingCount > 0) {
      note = `Retrying ${job.currentSong}. ${job.currentProviderPhase || "Trying fallback audio sources."}`;
    } else {
      note = job.missingCount > 0
        ? `We are retrying the remaining ${job.missingCount} file${job.missingCount === 1 ? "" : "s"} with fallback sources.`
        : "Checking whether any files still need another pass.";
    }
  } else if (job.phase === "Finished" || job.status === "completed") {
    activeKey = "done";
    note = job.missingCount > 0
      ? `Finished with ${job.downloadedCount || 0} downloaded and ${job.missingCount} still left.`
      : `Finished successfully. ${job.downloadedCount || 0} file${job.downloadedCount === 1 ? "" : "s"} downloaded.`;
  }

  const downloadedMention = /Downloaded "/.test(rawLog || "");
  if (activeKey === "matching" && downloadedMention) {
    activeKey = "downloading";
  }

  const sawRetry = hasRetryEvidence(job, rawLog);
  const activeIndex = steps.findIndex(step => step.key === activeKey);
  return {
    note,
    steps: steps.map((step, index) => ({
      ...step,
      badge:
        step.key === "retrying" && job.phase === "Retrying missing songs" ? { label: "Retrying", variant: "retrying" } :
        step.key === "retrying" && sawRetry ? { label: "Retried", variant: "retried" } :
        null,
      state:
        index < activeIndex ? "done" :
        index === activeIndex ? "active" :
        "todo",
    })),
  };
}

function formatMeta(job) {
  const lines = [];
  lines.push(`Stage: ${formatPhase(job.phase)}`);
  if (job.trackCount) lines.push(`Tracks found: ${job.trackCount}`);
  if (job.uniqueTrackCount) lines.push(`Unique tracks: ${job.uniqueTrackCount}`);
  if (job.uniqueTrackCount && job.phase !== "Finished") {
    lines.push(`Matches resolved: ${Math.min(job.matchCount || 0, job.uniqueTrackCount)} / ${job.uniqueTrackCount}`);
  }
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

function getLogLineVariant(line) {
  const bare = line.replace(/^\[[^\]]+\]\s*/, "");

  if (
    /generated an exception/i.test(bare) ||
    /Could not get/i.test(bare) ||
    /^Worker failed:/i.test(bare) ||
    /^The downloader stopped:/i.test(bare) ||
    /^AudioProviderError:/i.test(bare) ||
    /^LookupError:/i.test(bare)
  ) {
    return "error";
  }

  if (
    /^Retrying/i.test(bare) ||
    /logging error/i.test(bare) ||
    /live event will begin in/i.test(bare) ||
    /rate-limiting requests/i.test(bare) ||
    /continuing with \d+ saved songs/i.test(bare)
  ) {
    return "warning";
  }

  if (
    /^Finished\./i.test(bare) ||
    /^Saved \d+ songs to/i.test(bare) ||
    /^Downloaded:/i.test(bare) ||
    /^Canceled from the app\./i.test(bare)
  ) {
    return "success";
  }

  return "info";
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

function renderLogMarkup(logText, emptyLabel = "No log output yet.") {
  const lines = getLogLines(logText);
  if (lines.length === 0) {
    return `<span class="log-line" data-variant="info">${escapeHtml(emptyLabel)}</span>`;
  }

  return lines.map(line => {
    const human = humanizeLine(line);
    const variant = getLogLineVariant(human);
    return `<span class="log-line" data-variant="${variant}">${escapeHtml(human)}</span>`;
  }).join("\n");
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
    li.className = "empty-state";
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
  modalLog.innerHTML = renderLogMarkup(rawLog);
  logModal.showModal();
}

async function removeJob(job) {
  await fetchJson(`/api/jobs/${job.id}`, { method: "DELETE" });
  deletingJobs.add(job.id);
  try {
    lastJobsSignature = "";
    const data = await fetchJson("/api/jobs");
    const jobs = data.jobs || [];
    if (jobs.some(entry => entry.id === job.id)) {
      throw new Error("History was not removed from disk.");
    }

    const card = jobElements.get(job.id);
    if (card) {
      card.remove();
      jobElements.delete(job.id);
    }
    activeLogs.delete(job.id);
    jobStateCache.delete(job.id);
    setMessage(`Removed saved history for "${formatJobTitle(job)}".`, "success");

    if (!jobs.length) {
      jobsEl.innerHTML = '<p class="empty">No saved jobs yet.</p>';
    }
  } finally {
    deletingJobs.delete(job.id);
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

async function retryJob(job) {
  const nextJob = await startJob(job.url, job.id);
  setMessage(`Retry started for "${formatJobTitle(job)}".`, "success");
  await renderJobs();
  return nextJob;
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
    compactSummaryEl: fragment.querySelector(".compact-summary"),
    compactOpenFolderButtonEl: fragment.querySelector(".compact-open-folder-button"),
    compactRetryButtonEl: fragment.querySelector(".compact-retry-button"),
    compactLogButtonEl: fragment.querySelector(".compact-log-button"),
    compactRemoveButtonEl: fragment.querySelector(".compact-remove-button"),
    metaEl: fragment.querySelector(".meta"),
    progressNoteEl: fragment.querySelector(".progress-note"),
    progressStepsEl: fragment.querySelector(".progress-steps"),
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
    compactSummaryEl,
    compactOpenFolderButtonEl,
    compactRetryButtonEl,
    compactLogButtonEl,
    compactRemoveButtonEl,
    metaEl,
    progressNoteEl,
    progressStepsEl,
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
  card.dataset.compact = isCompactJob(job) ? "true" : "false";
  titleEl.textContent = formatJobTitle(job);
  urlEl.textContent = job.url;
  badgeEl.textContent = job.status;
  const compactSummary = getCompactSummary(job);
  compactSummaryEl.innerHTML = `
    <span class="compact-title">${escapeHtml(compactSummary.title)}</span>
    <span class="compact-status" data-status="${escapeHtml(compactSummary.status)}">${escapeHtml(compactSummary.status || "")}</span>
    <span class="compact-detail">${escapeHtml(compactSummary.detail || "")}</span>
  `;
  metaEl.innerHTML = formatMeta(job);
  const progress = getProgressModel(job, rawLog);
  progressNoteEl.textContent = progress.note;
  progressStepsEl.innerHTML = progress.steps.map(step => {
    const dot = step.state === "done" ? "Done" : step.state === "active" ? "Now" : "Next";
    const badgeHtml = step.badge
      ? `<span class="progress-step-state" data-variant="${step.badge.variant}">${escapeHtml(step.badge.label)}</span>`
      : "";
    return `<div class="progress-step" data-state="${step.state}"><div class="progress-step-main"><span class="progress-pill">${dot}</span><span class="progress-step-label">${escapeHtml(step.label)}</span></div>${badgeHtml}</div>`;
  }).join("");
  renderMissingSongs(job, missingEl);
  previewEl.innerHTML = renderLogMarkup(getLogLines(rawLog).slice(-4).join("\n"), "No log output yet.");
  previewEl.dataset.error = job.error ? "true" : "false";

  openFolderButtonEl.disabled = !job.outputFolder;
  cancelButtonEl.textContent = isRetryable(job) ? "Retry" : "Cancel";
  cancelButtonEl.disabled = !(job.status === "running" || job.status === "queued" || isRetryable(job));
  removeButtonEl.disabled = job.status === "running" || job.status === "queued";
  compactOpenFolderButtonEl.disabled = !job.outputFolder || job.status !== "completed";
  compactRetryButtonEl.disabled = !isRetryable(job);
  compactLogButtonEl.disabled = false;
  compactRemoveButtonEl.disabled = job.status === "running" || job.status === "queued";

  openFolderButtonEl.onclick = () => {
    if (!job.outputFolder) return;
    openFolder(job).catch(error => setMessage(error.message, "error"));
  };
  cancelButtonEl.onclick = () => {
    if (isRetryable(job)) {
      retryJob(job).catch(error => setMessage(error.message, "error"));
      return;
    }
    cancelJob(job).catch(error => setMessage(error.message, "error"));
  };
  logButtonEl.onclick = () => openLogModal(job, rawLog);
  removeButtonEl.onclick = () => {
    removeJob(job).catch(error => setMessage(error.message, "error"));
  };
  compactOpenFolderButtonEl.onclick = () => {
    if (!job.outputFolder || job.status !== "completed") return;
    openFolder(job).catch(error => setMessage(error.message, "error"));
  };
  compactRetryButtonEl.onclick = () => {
    if (!isRetryable(job)) return;
    retryJob(job).catch(error => setMessage(error.message, "error"));
  };
  compactLogButtonEl.onclick = () => openLogModal(job, rawLog);
  compactRemoveButtonEl.onclick = () => {
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
      matchCount: job.matchCount,
      currentSong: job.currentSong,
      currentProviderPhase: job.currentProviderPhase,
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
    const card = jobElements.get(job.id);
    if (card) {
      jobsEl.appendChild(card);
    }
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
    const job = await startJob(url);
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
