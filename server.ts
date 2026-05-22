const requestedPort = Number(Deno.args[0] ?? "8976");
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

async function readJob(jobId: string): Promise<JobRecord | null> {
  try {
    const text = await Deno.readTextFile(getJobFilePath(jobId));
    const cleaned = text.replace(/^\uFEFF/, "");
    return JSON.parse(cleaned) as JobRecord;
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

async function deleteIfExists(path: string) {
  try {
    await Deno.remove(path);
  } catch {
  }
}

async function createJob(url: string): Promise<JobRecord> {
  const id = crypto.randomUUID().replaceAll("-", "");
  const jobFolder = getJobDir(id);
  await Deno.mkdir(jobFolder, { recursive: true });
  const job: JobRecord = {
    id,
    url,
    status: "queued",
    phase: "Queued",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    playlistName: null,
    playlistId: null,
    outputFolder: null,
    trackCount: null,
    uniqueTrackCount: null,
    downloadedCount: 0,
    missingCount: null,
    missingSongs: [],
    logPath: `${jobFolder}\\log.txt`,
    metadataPath: `${jobFolder}\\playlist.spotdl`,
    workerPid: null,
    error: null,
  };
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

for (let offset = 0; offset < 15; offset++) {
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
    const body = await request.json().catch(() => null) as { url?: string } | null;
    if (!body?.url?.trim()) {
      return json({ error: "Missing playlist URL." }, 400);
    }

    const job = await createJob(body.url.trim());
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

    await deleteIfExists(`${historyRoot}\\${job.id}`);

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
  throw new Error(`Could not find an open port between ${requestedPort} and ${requestedPort + 14}.`);
}

console.log(`spotDL local web UI running at http://localhost:${serverPort}/`);
