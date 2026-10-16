import type {
  ArchiveFolderEntry,
  ArchiveFolderSnapshot,
  ArchiveRecord,
} from "./data";
import {
  detectNative,
  listDir,
  type NativeEntry,
  type NativeInfo,
} from "./native";

type PermissionMode = "read" | "readwrite";

type DirectoryEntryHandle = {
  kind: "file" | "directory";
  name: string;
  getFile?: () => Promise<File>;
  entries?: () => AsyncIterableIterator<[string, DirectoryEntryHandle]>;
  queryPermission?: (options?: { mode?: PermissionMode }) => Promise<string>;
  requestPermission?: (options?: { mode?: PermissionMode }) => Promise<string>;
};

type DirectoryHandle = DirectoryEntryHandle & {
  kind: "directory";
};

declare global {
  interface Window {
    showDirectoryPicker?: (options?: {
      id?: string;
      mode?: PermissionMode;
      startIn?: string;
    }) => Promise<DirectoryHandle>;
  }

  interface HTMLInputElement {
    directory?: boolean;
  }
}

const DB_NAME = "rhine-lab-document-access";
const DB_VERSION = 1;
const STORE_NAME = "handles";
const HANDLE_KEY = "documents";

export interface DocumentConnection {
  handle?: DirectoryHandle;
  folders: ArchiveFolderSnapshot[];
  persistent: boolean;
  native?: boolean;
}

function openHandleDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (!("indexedDB" in window)) {
      reject(new Error("IndexedDB unavailable"));
      return;
    }
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      request.result.createObjectStore(STORE_NAME);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB error"));
  });
}

async function loadHandle(): Promise<DirectoryHandle | undefined> {
  try {
    const db = await openHandleDb();
    return await new Promise<DirectoryHandle | undefined>((resolve, reject) => {
      const request = db
        .transaction(STORE_NAME, "readonly")
        .objectStore(STORE_NAME)
        .get(HANDLE_KEY);
      request.onsuccess = () => resolve(request.result as DirectoryHandle | undefined);
      request.onerror = () => reject(request.error);
    });
  } catch {
    return undefined;
  }
}

async function saveHandle(handle: DirectoryHandle) {
  try {
    const db = await openHandleDb();
    await new Promise<void>((resolve, reject) => {
      const request = db
        .transaction(STORE_NAME, "readwrite")
        .objectStore(STORE_NAME)
        .put(handle, HANDLE_KEY);
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
    });
  } catch {
    // Persistence is an enhancement. The current page can still rescan.
  }
}

async function permission(
  handle: DirectoryHandle,
  request = false,
): Promise<boolean> {
  const options = { mode: "read" as const };
  try {
    const current = await handle.queryPermission?.(options);
    if (current === "granted") return true;
    if (!request) return false;
    const next = await handle.requestPermission?.(options);
    return next === "granted";
  } catch {
    return false;
  }
}

function hidden(name: string) {
  return name.startsWith(".") || name === "DS_Store";
}

function extension(name: string) {
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toUpperCase() : "";
}

function sortEntries(entries: ArchiveFolderEntry[]) {
  return entries.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === "directory" ? -1 : 1;
    return a.name.localeCompare(b.name, "zh-CN", {
      numeric: true,
      sensitivity: "base",
    });
  });
}

async function readFolder(
  root: DirectoryHandle,
  folder: DirectoryHandle,
  key: string,
): Promise<ArchiveFolderSnapshot> {
  const entries: ArchiveFolderEntry[] = [];
  if (folder.entries) {
    for await (const [name, child] of folder.entries()) {
      if (hidden(name)) continue;
      if (child.kind === "file" && child.getFile) {
        try {
          const file = await child.getFile();
          entries.push({
            name,
            kind: "file",
            size: file.size,
            modified: file.lastModified,
            extension: extension(name),
            relativePath: `${root.name}/${folder.name}/${name}`,
          });
        } catch {
          entries.push({
            name,
            kind: "file",
            size: 0,
            modified: 0,
            extension: extension(name),
            relativePath: `${root.name}/${folder.name}/${name}`,
          });
        }
      } else {
        entries.push({
          name,
          kind: "directory",
          size: 0,
          modified: 0,
          extension: "",
          relativePath: `${root.name}/${folder.name}/${name}`,
        });
      }
    }
  }
  sortEntries(entries);
  const files = entries.filter((entry) => entry.kind === "file");
  const folders = entries.filter((entry) => entry.kind === "directory");
  const bytes = files.reduce((sum, entry) => sum + (entry.size ?? 0), 0);
  const lastModified = Math.max(
    0,
    ...entries.map((entry) => entry.modified ?? 0),
  );
  return {
    key,
    name: folder.name,
    path: `${root.name}/${folder.name}`,
    entries,
    itemCount: entries.length,
    fileCount: files.length,
    folderCount: folders.length,
    bytes,
    lastModified,
  };
}

export async function scanDocuments(handle: DirectoryHandle) {
  const folders: ArchiveFolderSnapshot[] = [];
  if (!handle.entries) return folders;
  for await (const [name, child] of handle.entries()) {
    if (hidden(name) || child.kind !== "directory") continue;
    folders.push(
      await readFolder(
        handle,
        child as DirectoryHandle,
        `${handle.name}/${name}`,
      ),
    );
  }
  folders.sort((a, b) => a.name.localeCompare(b.name, "zh-CN", { numeric: true }));
  return folders;
}

// ---------- 原生 App 模式（RhineLab.app）：经内嵌服务扫描 ~/Documents ----------

function nativeEntryToFolderEntry(
  entry: NativeEntry,
  displayPrefix: string,
): ArchiveFolderEntry {
  return {
    name: entry.name,
    kind: entry.kind,
    size: entry.size,
    modified: entry.modified,
    extension: entry.extension,
    relativePath: `${displayPrefix}/${entry.name}`,
    path: entry.path,
  };
}

async function readFolderNative(
  folder: NativeEntry,
  displayPrefix: string,
): Promise<ArchiveFolderSnapshot> {
  const children = await listDir(folder.path);
  const entries: ArchiveFolderEntry[] = [];
  for (const child of children) {
    if (hidden(child.name)) continue;
    entries.push(nativeEntryToFolderEntry(child, displayPrefix));
  }
  sortEntries(entries);
  const files = entries.filter((entry) => entry.kind === "file");
  const folders = entries.filter((entry) => entry.kind === "directory");
  const bytes = files.reduce((sum, entry) => sum + (entry.size ?? 0), 0);
  const lastModified = Math.max(
    0,
    ...entries.map((entry) => entry.modified ?? 0),
  );
  return {
    key: folder.path || folder.name,
    name: folder.name,
    path: displayPrefix,
    entries,
    itemCount: entries.length,
    fileCount: files.length,
    folderCount: folders.length,
    bytes,
    lastModified,
  };
}

async function scanDocumentsNative(
  native: NativeInfo,
): Promise<ArchiveFolderSnapshot[]> {
  const root = await listDir("");
  const folders: ArchiveFolderSnapshot[] = [];
  for (const child of root) {
    if (hidden(child.name) || child.kind !== "directory") continue;
    folders.push(
      await readFolderNative(child, `${native.documentsLabel}/${child.name}`),
    );
  }
  folders.sort((a, b) =>
    a.name.localeCompare(b.name, "zh-CN", { numeric: true }),
  );
  return folders;
}

function fallbackConnection(input: HTMLInputElement): Promise<DocumentConnection> {
  return new Promise((resolve) => {
    input.addEventListener(
      "change",
      () => {
        const files = [...(input.files ?? [])];
        const groups = new Map<string, ArchiveFolderEntry[]>();
        const rootName = files[0]?.webkitRelativePath?.split("/")[0] ?? "文稿";
        for (const file of files) {
          const parts = file.webkitRelativePath.split("/");
          const folderName = parts[1] ?? rootName;
          const key = `${rootName}/${folderName}`;
          const list = groups.get(key) ?? [];
          list.push({
            name: parts.at(-1) ?? file.name,
            kind: "file",
            size: file.size,
            modified: file.lastModified,
            extension: extension(file.name),
            relativePath: file.webkitRelativePath,
          });
          groups.set(key, list);
        }
        const folders = [...groups.entries()].map(([key, entries]) => {
          const name = key.split("/").at(-1) ?? key;
          sortEntries(entries);
          return {
            key,
            name,
            path: key,
            entries,
            itemCount: entries.length,
            fileCount: entries.length,
            folderCount: 0,
            bytes: entries.reduce((sum, entry) => sum + (entry.size ?? 0), 0),
            lastModified: Math.max(0, ...entries.map((entry) => entry.modified ?? 0)),
          } satisfies ArchiveFolderSnapshot;
        });
        input.remove();
        resolve({ folders, persistent: false });
      },
      { once: true },
    );
    input.click();
  });
}

export async function chooseDocumentsFolder(): Promise<DocumentConnection> {
  const native = await detectNative();
  if (native) {
    return {
      folders: await scanDocumentsNative(native),
      persistent: true,
      native: true,
    };
  }
  if (window.showDirectoryPicker) {
    const handle = await window.showDirectoryPicker({
      id: "rhine-lab-documents",
      mode: "read",
      startIn: "documents",
    });
    if (!(await permission(handle, true))) {
      throw new Error("文稿文件夹读取权限未授予");
    }
    await saveHandle(handle);
    return { handle, folders: await scanDocuments(handle), persistent: true };
  }
  const input = document.createElement("input");
  input.type = "file";
  input.multiple = true;
  input.webkitdirectory = true;
  input.directory = true;
  input.accept = "*/*";
  input.style.display = "none";
  document.body.appendChild(input);
  return fallbackConnection(input);
}

export async function restoreDocumentsFolder(): Promise<DocumentConnection | null> {
  const native = await detectNative();
  if (native) {
    return {
      folders: await scanDocumentsNative(native),
      persistent: true,
      native: true,
    };
  }
  const handle = await loadHandle();
  if (!handle || !(await permission(handle))) return null;
  return { handle, folders: await scanDocuments(handle), persistent: true };
}

export async function refreshDocumentsFolder(
  connection: DocumentConnection,
): Promise<DocumentConnection | null> {
  if (connection.native) {
    const native = await detectNative();
    if (!native) return null;
    return {
      ...connection,
      folders: await scanDocumentsNative(native),
    };
  }
  if (!connection.handle || !(await permission(connection.handle))) return null;
  return {
    ...connection,
    folders: await scanDocuments(connection.handle),
  };
}

export function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
}

export function formatDate(timestamp: number) {
  if (!timestamp) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(timestamp);
}

export function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

const DOCUMENT_COLUMNS = [
  "工程研究",
  "生命科学",
  "机构档案",
  "能量研究",
  "特别项目",
];

function stableHash(value: string) {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function folderAbstract(folder: ArchiveFolderSnapshot) {
  if (!folder.itemCount) {
    return `该目录当前为空。它位于 Finder 的“文稿”目录中，连接状态为只读；添加文件后重新扫描即可更新档案。`;
  }
  const folders = folder.folderCount ? `，含 ${folder.folderCount} 个子文件夹` : "";
  return `该档案映射到 Finder“文稿”中的“${folder.name}”文件夹，当前读取到 ${folder.fileCount} 个文件${folders}，合计 ${formatBytes(folder.bytes)}。这里只展示目录信息，不修改本地内容。`;
}

export function recordsFromFolders(folders: ArchiveFolderSnapshot[]): ArchiveRecord[] {
  return folders.map((folder, index) => {
    const category = DOCUMENT_COLUMNS[stableHash(folder.key) % DOCUMENT_COLUMNS.length];
    return {
      id: `X-${String(index + 1).padStart(3, "0")}`,
      title: folder.name,
      en: "FINDER DOCUMENT FOLDER",
      department: "本机文稿目录",
      category,
      date: `${folder.itemCount} 项 · ${formatBytes(folder.bytes)}`,
      lead: `~/Documents/${folder.name}`,
      clearance: "LOCAL · READ ONLY",
      abstract: folderAbstract(folder),
      findings: [
        `文件 ${folder.fileCount} 项 · 子文件夹 ${folder.folderCount} 项`,
        `当前目录大小 ${formatBytes(folder.bytes)}`,
        `最近更新时间 ${formatDate(folder.lastModified)}`,
      ],
      source: "",
      folder,
      localOnly: true,
    };
  });
}

export { DOCUMENT_COLUMNS };
