const form = document.querySelector("#download-form");
const input = document.querySelector("#playlist-url");
const jobsEl = document.querySelector("#jobs");
const messageEl = document.querySelector("#form-message");
const refreshBtn = document.querySelector("#refresh-jobs");
const template = document.querySelector("#job-template");

const activeLogs = new Map();

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

function formatJobTitle(job) {
  return job.playlistName || job.url;
}

function formatMeta(job) {
  const lines = [];
  lines.push(`Phase: ${job.phase || "-"}`);
  if (job.trackCount) lines.push(`Tracks: ${job.trackCount}`);
  if (job.uniqueTrackCount) lines.push(`Unique tracks: ${job.uniqueTrackCount}`);
  lines.push(`Downloaded files: ${job.downloadedCount || 0}`);
  if (job.missingCount !== null && job.missingCount !== undefined) {
    lines.push(`Missing after retries: ${job.missingCount}`);
  }
  if (job.outputFolder) lines.push(`Folder: ${job.outputFolder}`);
  if (job.error) lines.push(`Error: ${job.error}`);
  return lines.map(line => `<span>${escapeHtml(line)}</span>`).join("");
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

async function loadLog(jobId, logEl) {
  try {
    const data = await fetchJson(`/api/jobs/${jobId}/log`);
    const nextLog = data.log || "";
    if (activeLogs.get(jobId) !== nextLog) {
      activeLogs.set(jobId, nextLog);
      logEl.textContent = nextLog.trim() || "No log output yet.";
    }
  } catch (error) {
    logEl.textContent = error.message;
  }
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

async function renderJobs() {
  const data = await fetchJson("/api/jobs");
  const jobs = data.jobs || [];
  jobsEl.innerHTML = "";

  if (jobs.length === 0) {
    jobsEl.innerHTML = '<p class="empty">No jobs yet.</p>';
    return;
  }

  for (const job of jobs) {
    const fragment = template.content.cloneNode(true);
    const jobEl = fragment.querySelector(".job");
    const titleEl = fragment.querySelector(".job-title");
    const urlEl = fragment.querySelector(".job-url");
    const badgeEl = fragment.querySelector(".badge");
    const metaEl = fragment.querySelector(".meta");
    const missingEl = fragment.querySelector(".missing-list");
    const logEl = fragment.querySelector(".log");
    const logWrapEl = fragment.querySelector(".log-wrap");

    jobEl.dataset.status = job.status;
    titleEl.textContent = formatJobTitle(job);
    urlEl.textContent = job.url;
    badgeEl.textContent = job.status;
    metaEl.innerHTML = formatMeta(job);
    renderMissingSongs(job, missingEl);
    await loadLog(job.id, logEl);
    if (job.error) {
      logWrapEl.dataset.error = "true";
    }
    jobsEl.appendChild(fragment);
  }
}

form.addEventListener("submit", async event => {
  event.preventDefault();
  const url = input.value.trim();
  if (!url) return;

  const button = form.querySelector("button[type='submit']");
  button.disabled = true;
  setMessage("Starting download job...", "");

  try {
    await fetchJson("/api/downloads", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url })
    });
    input.value = "";
    setMessage("Job started. The page will keep updating automatically.", "success");
    await renderJobs();
  } catch (error) {
    setMessage(error.message, "error");
  } finally {
    button.disabled = false;
  }
});

refreshBtn.addEventListener("click", () => {
  renderJobs().catch(error => setMessage(error.message, "error"));
});

renderJobs().catch(error => setMessage(error.message, "error"));
setInterval(() => {
  renderJobs().catch(() => {});
}, 5000);
