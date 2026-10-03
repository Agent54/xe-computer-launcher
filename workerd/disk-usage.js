// Inventory reads Docker metadata only. /system/df is exclusively opt-in.
const services = new WeakMap();
const bytes = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : undefined;
const list = value => Array.isArray(value) ? value : [];
const sum = values => values.reduce((total, value) => total + (value ?? 0), 0);
const containerName = row => list(row.Names)[0]?.replace(/^\//, '') || row.Id?.slice(0, 12) || 'Unnamed container';
const inactive = state => ['created', 'exited', 'dead'].includes(state);

export function summarizeDiskUsage(data, sampledAt) {
  const images = list(data.Images);
  const containers = list(data.Containers);
  const volumes = list(data.Volumes);
  const cache = [...new Map(list(data.BuildCache).map(row => [row.ID, row])).values()];
  const items = [
    ...images.map(row => ({
      kind: 'images', name: list(row.RepoTags).filter(tag => tag !== '<none>:<none>').join(', ') || row.Id?.slice(7, 19) || 'Untagged image',
      bytes: bytes(row.Size), reclaimableBytes: row.Containers > 0 ? 0 : row.Containers === 0 && bytes(row.SharedSize) !== undefined && bytes(row.Size) !== undefined
        ? Math.max(0, row.Size - row.SharedSize) : undefined,
      candidate: row.Containers === 0, detail: `${row.Containers ?? 'Unknown'} container references; ${bytes(row.SharedSize) ?? 'unknown'} shared bytes`,
    })),
    ...containers.map(row => ({
      kind: 'containers', name: containerName(row), bytes: bytes(row.SizeRw),
      reclaimableBytes: inactive(row.State) ? bytes(row.SizeRw) : 0,
      candidate: inactive(row.State), detail: `${row.State || 'Unknown state'} · ${row.Labels?.['com.docker.compose.project'] || 'No Compose project'}`,
    })),
    ...volumes.map(row => ({
      kind: 'volumes', name: row.Name, bytes: bytes(row.UsageData?.Size),
      reclaimableBytes: row.UsageData?.RefCount === 0 ? bytes(row.UsageData?.Size) : 0,
      candidate: row.UsageData?.RefCount === 0, detail: `${row.UsageData?.RefCount ?? 'Unknown'} container references · ${row.Driver || 'Unknown driver'}`,
    })),
    ...cache.map(row => ({
      kind: 'build-cache', name: row.Description || row.ID, bytes: bytes(row.Size),
      reclaimableBytes: row.InUse === false && row.Shared === false ? bytes(row.Size) : 0,
      candidate: row.InUse === false, detail: row.InUse ? 'In use' : row.Shared ? 'Unused; shares image layers' : 'Unused build cache',
    })),
  ];
  const category = (kind, label, totalBytes, note) => {
    const rows = items.filter(row => row.kind === kind);
    return { kind, label, count: rows.length, candidateCount: rows.filter(row => row.candidate).length,
      totalBytes, reclaimableBytes: rows.some(row => row.candidate && row.reclaimableBytes === undefined)
        ? undefined : sum(rows.map(row => row.reclaimableBytes)), note };
  };
  const total = kind => {
    const rows = items.filter(row => row.kind === kind);
    return rows.some(row => row.bytes === undefined) ? undefined : sum(rows.map(row => row.bytes));
  };
  return {
    invalidate() {
      inventory = undefined;
      report = undefined;
      scanRetryAt = 0;
      scanError = undefined;
    },
    sampledAt,
    categories: [
      category('images', 'Images', bytes(data.LayersSize), 'Reclaimable estimate counts unused unique layers only; shared layers may free additional space.'),
      category('containers', 'Container files', total('containers'), 'Writable layers only. Container logs and bind mounts are not included. Removing stopped containers loses their writable files.'),
      category('volumes', 'Volumes', total('volumes'), 'Unused volumes can contain databases or other persistent data. Review and back up each volume before removal.'),
      category('build-cache', 'Build cache', total('build-cache'), 'Reclaimable estimate excludes shared image layers. Pruning makes later builds download or rebuild layers.'),
    ],
    items: items.sort((a, b) => (b.bytes ?? -1) - (a.bytes ?? -1)),
  };
}

export function createDiskUsageService(docker, { now = Date.now, scanTimeoutMs = 60_000 } = {}) {
  let inventory;
  let inventoryAt = -Infinity;
  let inventoryPending;
  let report;
  let scanPending;
  let scanRetryAt = 0;
  let scanError;

  async function read(path, signal) {
    const response = await docker.fetch(`http://docker${path}`, { method: 'GET', signal });
    if (!response.ok) throw new Error(`Docker disk report failed (${response.status}). Try again when the VM is idle.`);
    return await response.json();
  }

  async function overview() {
    if (inventory && now() - inventoryAt < 60_000) return inventory;
    if (inventoryPending) return await inventoryPending;
    inventoryPending = (async () => {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 5000);
      try {
        const [imageRows, containerRows, volumeData] = await Promise.all([
          read('/images/json?all=true', controller.signal),
          read('/containers/json?all=true&size=false', controller.signal),
          read('/volumes', controller.signal),
        ]);
        const containers = list(containerRows);
        const imageIDs = new Set(containers.map(row => row.ImageID));
        const references = new Map();
        for (const row of containers) for (const mount of list(row.Mounts)) {
          if (mount.Type === 'volume' && mount.Name) {
            if (!references.has(mount.Name)) references.set(mount.Name, new Set());
            references.get(mount.Name).add(row.Id);
          }
        }
        inventory = {
          sampledAt: new Date(now()).toISOString(),
          imageCount: list(imageRows).length,
          unusedImageCount: list(imageRows).filter(row => !imageIDs.has(row.Id)).length,
          containerCount: containers.length,
          stoppedContainerCount: containers.filter(row => inactive(row.State)).length,
          volumes: list(volumeData.Volumes).map(row => ({ name: row.Name, driver: row.Driver,
            references: references.get(row.Name)?.size ?? 0, project: row.Labels?.['com.docker.compose.project'] })),
        };
        inventoryAt = now();
        return inventory;
      } catch (error) {
        controller.abort();
        throw error;
      } finally { clearTimeout(timer); }
    })();
    try { return await inventoryPending; } finally { inventoryPending = undefined; }
  }

  async function scan() {
    if (scanPending) return await scanPending;
    if (now() < scanRetryAt) {
      if (scanError) throw new Error(scanError);
      return report;
    }
    scanPending = (async () => {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), scanTimeoutMs);
      try {
        // No arbitrary Docker path, prune endpoint or command is accepted.
        report = summarizeDiskUsage(await read('/system/df', controller.signal), new Date(now()).toISOString());
        scanRetryAt = now() + 300_000;
        scanError = undefined;
        return report;
      } catch (error) {
        scanError = controller.signal.aborted
          ? 'Disk analysis exceeded 60 seconds. Try again when builds are idle.' : error.message;
        scanRetryAt = now() + 60_000;
        throw new Error(scanError);
      } finally { clearTimeout(timer); }
    })();
    try { return await scanPending; } finally { scanPending = undefined; }
  }

  return {
    async response(scanRequested) {
      const headers = { 'Cache-Control': 'no-store' };
      try {
        const data = scanRequested ? { report: await scan() } : { inventory: await overview(), report };
        return Response.json({ ...data, scanError, nextScanAt: scanRetryAt ? new Date(scanRetryAt).toISOString() : null }, { headers });
      } catch (error) {
        return Response.json({ message: error.message, nextScanAt: new Date(scanRetryAt).toISOString() }, { status: 503, headers });
      }
    },
  };
}

export function invalidateDiskUsage(docker) {
  services.get(docker)?.invalidate();
}

export async function diskUsageResponse(docker, scan) {
  if (!docker) return Response.json({ message: 'Disk usage is unavailable in this launcher version.' }, { status: 503 });
  let service = services.get(docker);
  if (!service) { service = createDiskUsageService(docker); services.set(docker, service); }
  return await service.response(scan);
}
