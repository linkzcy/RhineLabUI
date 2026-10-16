// 原生 App 桥接层：在 RhineLab.app（WKWebView 内嵌 HTTP 服务）中可用；
// 浏览器环境自动回退到 File System Access API（documents.ts 原有逻辑）。

export interface NativeEntry {
  name: string;
  kind: "file" | "directory";
  size: number;
  modified: number;
  extension: string;
  path: string;
}

export interface NativeInfo {
  app: boolean;
  version: string;
  documentsLabel: string;
  documentsRoot: string;
  homeLabel: string;
}

export type PreviewKind =
  | "image"
  | "pdf"
  | "office"
  | "text"
  | "audio"
  | "video"
  | "other";

let nativeInfo: NativeInfo | null | undefined;

async function api<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, init);
  const data = (await response.json().catch(() => ({}))) as T & {
    error?: string;
  };
  if (!response.ok) throw new Error(data.error ?? `HTTP ${response.status}`);
  return data;
}

export async function detectNative(): Promise<NativeInfo | null> {
  if (nativeInfo !== undefined) return nativeInfo;
  try {
    const info = await api<NativeInfo & { app?: boolean }>("/api/info", {
      cache: "no-store",
    });
    nativeInfo = info.app ? info : null;
  } catch {
    nativeInfo = null;
  }
  return nativeInfo;
}

export async function listDir(path: string): Promise<NativeEntry[]> {
  const data = await api<{ entries: NativeEntry[] }>(
    `/api/list?path=${encodeURIComponent(path)}`,
    { cache: "no-store" },
  );
  return data.entries;
}

export async function readText(
  path: string,
  maxBytes = 512 * 1024,
): Promise<{ text: string; truncated: boolean; bytes: number }> {
  return api(`/api/text?path=${encodeURIComponent(path)}&max=${maxBytes}`, {
    cache: "no-store",
  });
}

export interface ConvertResult {
  ok: boolean;
  fileUrl?: string;
  pages?: number;
  html?: string;
  error?: string;
}

export async function convertOffice(path: string): Promise<ConvertResult> {
  return api(`/api/convert?path=${encodeURIComponent(path)}`, {
    cache: "no-store",
  });
}

export async function openWithDefaultApp(path: string) {
  await api("/api/open", {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: path,
  });
}

export async function revealInFinder(path: string) {
  await api("/api/reveal", {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: path,
  });
}

export function fileUrl(path: string) {
  return `/files/${encodeURIComponent(path)}`;
}

export function thumbUrl(path: string, px = 640) {
  return `/thumb/${encodeURIComponent(path)}?px=${px}`;
}

const IMAGE_EXTENSIONS = new Set([
  "PNG",
  "JPG",
  "JPEG",
  "GIF",
  "WEBP",
  "SVG",
  "HEIC",
  "AVIF",
  "BMP",
  "TIFF",
  "TIF",
  "ICO",
]);

const TEXT_EXTENSIONS = new Set([
  "TXT",
  "MD",
  "MARKDOWN",
  "JSON",
  "CSV",
  "TSV",
  "LOG",
  "YML",
  "YAML",
  "XML",
  "HTML",
  "HTM",
  "JS",
  "MJS",
  "CJS",
  "TS",
  "JSX",
  "TSX",
  "CSS",
  "SCSS",
  "PY",
  "SH",
  "BASH",
  "ZSH",
  "C",
  "H",
  "CPP",
  "HPP",
  "JAVA",
  "SQL",
  "INI",
  "TOML",
  "CONF",
  "CFG",
  "SRT",
  "VTT",
  "LRC",
  "TEX",
  "SVG",
]);

const OFFICE_EXTENSIONS = new Set([
  "DOC",
  "DOCX",
  "XLS",
  "XLSX",
  "PPT",
  "PPTX",
  "ODT",
  "ODS",
  "ODP",
  "RTF",
  "PAGES",
  "NUMBERS",
  "KEY",
]);

const AUDIO_EXTENSIONS = new Set([
  "MP3",
  "WAV",
  "M4A",
  "AAC",
  "FLAC",
  "OGG",
  "AIFF",
  "AIF",
  "CAF",
]);

const VIDEO_EXTENSIONS = new Set([
  "MP4",
  "MOV",
  "M4V",
  "WEBM",
  "MKV",
  "AVI",
]);

export function previewKind(name: string, ext = ""): PreviewKind {
  const extension = ext || name.split(".").pop()?.toUpperCase() || "";
  if (name.toUpperCase().endsWith(".PDF") || extension === "PDF") return "pdf";
  if (IMAGE_EXTENSIONS.has(extension)) return "image";
  if (OFFICE_EXTENSIONS.has(extension)) return "office";
  if (TEXT_EXTENSIONS.has(extension)) return "text";
  if (AUDIO_EXTENSIONS.has(extension)) return "audio";
  if (VIDEO_EXTENSIONS.has(extension)) return "video";
  return "other";
}
