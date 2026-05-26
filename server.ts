const requestedPort = Number(Deno.args[0] ?? "8976");
const strictPort = Deno.env.get("SPOTDL_STRICT_PORT") === "1";
const root = Deno.cwd();
const webRoot = `${root}\\web`;
const dataRoot = `${root}\\app-data`;
const historyRoot = `${dataRoot}\\history`;
const downloadsRoot = `${root}\\downloads`;
const workerScript = `${root}\\download-worker.ps1`;

for (const path of [webRoot, dataRoot, historyRoot, downloadsRoot]) {
  await Deno.mkdir(path, { recursive: true });
}

type JobRecord = {
  id: string;
  url: string;
  urlType: "playlist" | "track" | "artist" | "album" | "unknown";
  status: string;
  phase: string;
  createdAt: string;
  updatedAt: string;
  playlistName: string | null;
  playlistId: string | null;
  outputFolder: string | null;
  trackCount: number | null;
  uniqueTrackCount: number | null;
  downloadedCount: number;
  missingCount: number | null;
  missingSongs: Array<{ artist: string; title: string; url: string }>;
  logPath: string;
  metadataPath: string;
  workerPid: number | null;
  matchCount: number;
  currentSong: string | null;
  currentProviderPhase: string | null;
  retryOf: string | null;
  resumeFromJobId: string | null;
  resumeOnlyMissing: boolean;
  resumeOutputFolder: string | null;
  missingSongsKnown: boolean;
  replacedByJobId: string | null;
  error: string | null;
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function getJobDir(jobId: string) {
  return `${historyRoot}\\${jobId}`;
}

function getJobFilePath(jobId: string) {
  return `${getJobDir(jobId)}\\job.json`;
}

async function writeJob(job: JobRecord) {
  await Deno.mkdir(getJobDir(job.id), { recursive: true });
  await Deno.writeTextFile(getJobFilePath(job.id), JSON.stringify(job, null, 2));
}

function normalizeJob(job: Partial<JobRecord>): JobRecord {
  const normalizedMissingSongs = Array.isArray(job.missingSongs)
    ? job.missingSongs
    : job.missingSongs
      ? [job.missingSongs as JobRecord["missingSongs"][number]]
      : [];
  const normalizedMissingCount = typeof job.missingCount === "number"
    ? job.missingCount
    : (job.status === "completed" || job.status === "failed" || job.status === "canceled")
      ? normalizedMissingSongs.length
      : null;
  return {
    id: job.id ?? "",
    url: job.url ?? "",
    urlType: job.urlType ?? detectSpotifyUrlType(job.url ?? ""),
    status: job.status ?? "queued",
    phase: job.phase ?? "Queued",
    createdAt: job.createdAt ?? new Date(0).toISOString(),
    updatedAt: job.updatedAt ?? new Date(0).toISOString(),
    playlistName: job.playlistName ?? null,
    playlistId: job.playlistId ?? null,
    outputFolder: job.outputFolder ?? null,
    trackCount: job.trackCount ?? null,
    uniqueTrackCount: job.uniqueTrackCount ?? null,
    downloadedCount: job.downloadedCount ?? 0,
    missingCount: normalizedMissingCount,
    missingSongs: normalizedMissingSongs,
    logPath: job.logPath ?? "",
    metadataPath: job.metadataPath ?? "",
    workerPid: job.workerPid ?? null,
    matchCount: job.matchCount ?? 0,
    currentSong: job.currentSong ?? null,
    currentProviderPhase: job.currentProviderPhase ?? null,
    retryOf: job.retryOf ?? null,
    resumeFromJobId: job.resumeFromJobId ?? null,
    resumeOnlyMissing: job.resumeOnlyMissing ?? false,
    resumeOutputFolder: job.resumeOutputFolder ?? null,
    missingSongsKnown: job.missingSongsKnown ?? (job.status === "completed" || job.status === "failed" || job.status === "canceled"),
    replacedByJobId: job.replacedByJobId ?? null,
    error: job.error ?? null,
  };
}

function detectSpotifyUrlType(url: string): JobRecord["urlType"] {
  const match = url.match(/open\.spotify\.com\/(playlist|track|artist|album)\//i);
  const kind = match?.[1]?.toLowerCase();
  if (kind === "playlist" || kind === "track" || kind === "artist" || kind === "album") {
    return kind;
  }
  return "unknown";
}

async function readJob(jobId: string): Promise<JobRecord | null> {
  try {
    const text = await Deno.readTextFile(getJobFilePath(jobId));
    const cleaned = text.replace(/^\uFEFF/, "");
    return normalizeJob(JSON.parse(cleaned) as Partial<JobRecord>);
  } catch {
    return null;
  }
}

async function readAllJobs(): Promise<JobRecord[]> {
  const jobs: JobRecord[] = [];
  for await (const entry of Deno.readDir(historyRoot)) {
    if (!entry.isDirectory) continue;
    const job = await readJob(entry.name);
    if (job) jobs.push(job);
  }
  jobs.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  return jobs;
}

async function migrateLegacyJobs() {
  const legacyJobsRoot = `${dataRoot}\\jobs`;
  const legacyLogsRoot = `${dataRoot}\\logs`;

  try {
    for await (const entry of Deno.readDir(legacyJobsRoot)) {
      if (!entry.isFile || !entry.name.endsWith(".json")) continue;
      const jobId = entry.name.replace(/\.json$/, "");
      const targetFolder = `${historyRoot}\\${jobId}`;
      const targetJobFile = getJobFilePath(jobId);

      try {
        await Deno.stat(targetJobFile);
        continue;
      } catch {
      }

      await Deno.mkdir(targetFolder, { recursive: true });
      await Deno.copyFile(`${legacyJobsRoot}\\${entry.name}`, targetJobFile);

      try {
        await Deno.copyFile(`${legacyJobsRoot}\\${jobId}.spotdl`, `${targetFolder}\\playlist.spotdl`);
      } catch {
      }

      try {
        await Deno.copyFile(`${legacyLogsRoot}\\${jobId}.log`, `${targetFolder}\\log.txt`);
      } catch {
        try {
          await Deno.copyFile(`${legacyJobsRoot}\\${jobId}.log`, `${targetFolder}\\log.txt`);
        } catch {
        }
      }
    }
  } catch {
  }
}

async function deleteIfExists(path: string, recursive = false) {
  try {
    await Deno.remove(path, { recursive });
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return;
    }
    throw error;
  }
}

async function exists(path: string) {
  try {
    await Deno.stat(path);
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return false;
    }
    throw error;
  }
}

async function removeJobArtifacts(jobId: string) {
  const targets = [
    { path: getJobDir(jobId), recursive: true },
    { path: `${dataRoot}\\jobs\\${jobId}.json`, recursive: false },
    { path: `${dataRoot}\\jobs\\${jobId}.spotdl`, recursive: false },
    { path: `${dataRoot}\\jobs\\${jobId}.log`, recursive: false },
    { path: `${dataRoot}\\logs\\${jobId}.log`, recursive: false },
  ];

  let lastError: unknown = null;
  for (let attempt = 0; attempt < 5; attempt++) {
    lastError = null;
    try {
      for (const target of targets) {
        await deleteIfExists(target.path, target.recursive);
      }
      if (!(await exists(getJobDir(jobId)))) {
        return;
      }
      lastError = new Error("Saved history folder still exists after delete.");
    } catch (error) {
      lastError = error;
    }

    await new Promise(resolve => setTimeout(resolve, 200));
  }

  throw lastError instanceof Error
    ? lastError
    : new Error("Saved history could not be removed from disk.");
}

async function createJob(
  url: string,
  options: {
    retryOf?: string | null;
    resumeOnlyMissing?: boolean;
  } = {},
): Promise<JobRecord> {
  const id = crypto.randomUUID().replaceAll("-", "");
  const jobFolder = getJobDir(id);
  await Deno.mkdir(jobFolder, { recursive: true });
  const retryOf = options.retryOf?.trim() || null;
  const sourceJob = retryOf ? await readJob(retryOf) : null;
  const resumeOnlyMissing = Boolean(options.resumeOnlyMissing);
  const job: JobRecord = {
    id,
    url,
    urlType: sourceJob?.urlType ?? detectSpotifyUrlType(url),
    status: "queued",
    phase: "Queued",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    playlistName: sourceJob?.playlistName ?? null,
    playlistId: sourceJob?.playlistId ?? null,
    outputFolder: null,
    trackCount: sourceJob?.trackCount ?? null,
    uniqueTrackCount: sourceJob?.uniqueTrackCount ?? null,
    downloadedCount: 0,
    missingCount: null,
    missingSongs: [],
    logPath: `${jobFolder}\\log.txt`,
    metadataPath: `${jobFolder}\\playlist.spotdl`,
    workerPid: null,
    matchCount: 0,
    currentSong: null,
    currentProviderPhase: null,
    retryOf,
    resumeFromJobId: sourceJob?.id ?? null,
    resumeOnlyMissing,
    resumeOutputFolder: resumeOnlyMissing ? sourceJob?.outputFolder ?? null : null,
    missingSongsKnown: false,
    replacedByJobId: null,
    error: null,
  };

  if (sourceJob && resumeOnlyMissing) {
    try {
      await Deno.copyFile(sourceJob.metadataPath, job.metadataPath);
    } catch {
    }

    sourceJob.replacedByJobId = id;
    await writeJob(sourceJob);
  } else if (sourceJob && sourceJob.urlType === "artist") {
    sourceJob.replacedByJobId = id;
    await writeJob(sourceJob);
  }

  await writeJob(job);
  return job;
}

function contentType(path: string) {
  if (path.endsWith(".html")) return "text/html; charset=utf-8";
  if (path.endsWith(".js")) return "application/javascript; charset=utf-8";
  if (path.endsWith(".css")) return "text/css; charset=utf-8";
  return "application/octet-stream";
}

async function serveFile(path: string) {
  try {
    const body = await Deno.readFile(path);
    return new Response(body, {
      headers: { "content-type": contentType(path) },
    });
  } catch {
    return new Response("Not found", { status: 404 });
  }
}

async function spawnWorker(jobId: string) {
  const command = new Deno.Command("powershell.exe", {
    args: [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      workerScript,
      "-JobId",
      jobId,
      "-RootPath",
      root,
    ],
    cwd: root,
    stdout: "null",
    stderr: "null",
  });

  const child = command.spawn();
  const job = await readJob(jobId);
  if (job) {
    job.workerPid = child.pid;
    await writeJob(job);
  }
}

async function appendServerLog(logPath: string, message: string) {
  const line = `[${new Date().toLocaleString("en-US", { hour12: true })}] ${message}\n`;
  await Deno.writeTextFile(logPath, line, { append: true, create: true });
}

await migrateLegacyJobs();
let serverPort = requestedPort;
let started = false;

const maxPortAttempts = strictPort ? 1 : 15;

for (let offset = 0; offset < maxPortAttempts; offset++) {
  const tryPort = requestedPort + offset;
  try {
    Deno.serve({ hostname: "127.0.0.1", port: tryPort }, async (request) => {
  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === "/") {
    return serveFile(`${webRoot}\\index.html`);
  }

  if (request.method === "GET" && url.pathname === "/app.js") {
    return serveFile(`${webRoot}\\app.js`);
  }

  if (request.method === "GET" && url.pathname === "/styles.css") {
    return serveFile(`${webRoot}\\styles.css`);
  }

  if (request.method === "GET" && url.pathname === "/api/jobs") {
    return json({ jobs: await readAllJobs() });
  }

  if (request.method === "POST" && url.pathname === "/api/downloads") {
    const body = await request.json().catch(() => null) as { url?: string; retryOf?: string; resumeOnlyMissing?: boolean } | null;
    if (!body?.url?.trim()) {
      return json({ error: "Missing playlist URL." }, 400);
    }

    const job = await createJob(body.url.trim(), {
      retryOf: body.retryOf?.trim() || null,
      resumeOnlyMissing: body.resumeOnlyMissing === true,
    });
    await spawnWorker(job.id);
    return json(job, 202);
  }

  const logMatch = url.pathname.match(/^\/api\/jobs\/([a-z0-9]+)\/log$/);
  if (request.method === "GET" && logMatch) {
    const job = await readJob(logMatch[1]);
    if (!job) return json({ error: "Job not found." }, 404);
    let log = "";
    try {
      log = await Deno.readTextFile(job.logPath);
    } catch {
    }
    return json({ id: job.id, log });
  }

  const jobMatch = url.pathname.match(/^\/api\/jobs\/([a-z0-9]+)$/);
  if (request.method === "GET" && jobMatch) {
    const job = await readJob(jobMatch[1]);
    if (!job) return json({ error: "Job not found." }, 404);
    return json(job);
  }

  if (request.method === "DELETE" && jobMatch) {
    const job = await readJob(jobMatch[1]);
    if (!job) return json({ error: "Job not found." }, 404);
    if (job.status === "running" || job.status === "queued") {
      return json({ error: "You can remove history only after the job finishes." }, 409);
    }

    try {
      await removeJobArtifacts(job.id);
    } catch (error) {
      return json({ error: `Could not remove saved history. ${error instanceof Error ? error.message : "Unknown delete error."}` }, 500);
    }

    return json({ ok: true, id: job.id });
  }

  const cancelMatch = url.pathname.match(/^\/api\/jobs\/([a-z0-9]+)\/cancel$/);
  if (request.method === "POST" && cancelMatch) {
    const job = await readJob(cancelMatch[1]);
    if (!job) return json({ error: "Job not found." }, 404);
    if (job.status !== "running" && job.status !== "queued") {
      return json({ error: "This job is not currently running." }, 409);
    }

    if (job.workerPid) {
      try {
        await new Deno.Command("taskkill", {
          args: ["/PID", String(job.workerPid), "/T", "/F"],
          stdout: "null",
          stderr: "null",
        }).output();
      } catch {
      }
    }

    job.status = "canceled";
    job.phase = "Canceled";
    job.error = null;
    job.workerPid = null;
    await writeJob(job);
    await appendServerLog(job.logPath, "Canceled by user.");
    return json({ ok: true, id: job.id });
  }

  const openFolderMatch = url.pathname.match(/^\/api\/jobs\/([a-z0-9]+)\/open-folder$/);
  if (request.method === "POST" && openFolderMatch) {
    const job = await readJob(openFolderMatch[1]);
    if (!job) return json({ error: "Job not found." }, 404);
    if (!job.outputFolder) return json({ error: "No output folder available yet." }, 409);

    try {
      new Deno.Command("explorer.exe", {
        args: [job.outputFolder],
        stdout: "null",
        stderr: "null",
      }).spawn();
    } catch {
      return json({ error: "Could not open the folder on this computer." }, 500);
    }

    return json({ ok: true, folder: job.outputFolder });
  }

  return json({ error: "Not found." }, 404);
});

    serverPort = tryPort;
    started = true;
    break;
  } catch (error) {
    if (!(error instanceof Deno.errors.AddrInUse)) {
      throw error;
    }
  }
}

if (!started) {
  if (strictPort) {
    throw new Error(`Could not start the local web UI on port ${requestedPort}.`);
  }
  throw new Error(`Could not find an open port between ${requestedPort} and ${requestedPort + 14}.`);
}

console.log(`spotDL local web UI running at http://localhost:${serverPort}/`);
