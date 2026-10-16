// 详情页「研究记录」标签的文件树浏览与全屏文件预览面板。
// 仅在原生 App 模式（RhineLab.app）提供预览与打开；浏览器模式回退为只读列表。
import type { ArchiveFolderEntry, ArchiveFolderSnapshot } from "./data";
import { escapeHtml, formatBytes, formatDate } from "./documents";
import {
  convertOffice,
  detectNative,
  fileUrl,
  listDir,
  openWithDefaultApp,
  previewKind,
  readText,
  revealInFinder,
  thumbUrl,
  type ConvertResult,
  type NativeEntry,
  type PreviewKind,
} from "./native";

interface BrowserOptions {
  notify: (message: string) => void;
}

function kindBadge(entry: ArchiveFolderEntry | NativeEntry) {
  if (entry.kind === "directory") return "DIR";
  return entry.extension || "FILE";
}

function entryToFolderEntry(entry: NativeEntry): ArchiveFolderEntry {
  return {
    name: entry.name,
    kind: entry.kind,
    size: entry.size,
    modified: entry.modified,
    extension: entry.extension,
    relativePath: entry.path,
    path: entry.path,
  };
}

export class FileBrowser {
  private root: ArchiveFolderSnapshot | null = null;
  private container: HTMLElement | null = null;
  private children = new Map<string, ArchiveFolderEntry[]>();
  private expanded = new Set<string>();
  private previewEntry: ArchiveFolderEntry | null = null;
  private previewKindValue: PreviewKind = "other";
  private disposeFns: (() => void)[] = [];
  private bound = {
    click: (e: MouseEvent) => this.onClick(e),
    keydown: (e: KeyboardEvent) => this.onKeydown(e),
  };

  constructor(private options: BrowserOptions) {}

  get isPreviewOpen() {
    return this.previewEntry !== null;
  }

  private $ = <T extends HTMLElement = HTMLElement>(selector: string) =>
    document.querySelector<T>(selector)!;

  // ---------- 树视图 ----------

  mount(container: HTMLElement, folder: ArchiveFolderSnapshot) {
    this.unmount();
    this.root = folder;
    this.container = container;
    container.addEventListener("click", this.bound.click);
    container.addEventListener("keydown", this.bound.keydown);
    this.renderTree();
  }

  unmount() {
    this.closePreview();
    if (this.container) {
      this.container.removeEventListener("click", this.bound.click);
      this.container.removeEventListener("keydown", this.bound.keydown);
      this.container = null;
    }
    this.root = null;
    this.children.clear();
    this.expanded.clear();
    this.disposeFns.forEach((fn) => fn());
    this.disposeFns = [];
  }

  private renderTree() {
    if (!this.root || !this.container) return;
    const folder = this.root;
    const rows = folder.entries
      .map((entry) => this.rowMarkup(entry, 0))
      .join("");
    this.container.innerHTML = `
      <div class="folder-file-tree" role="tree">
        <div class="tree-breadcrumb">FINDER <i>／</i> ${escapeHtml(folder.path)}</div>
        ${rows || `<div class="folder-empty">此文件夹当前为空。在 Finder 中添加文件后会自动更新。</div>`}
      </div>`;
  }

  private rowMarkup(entry: ArchiveFolderEntry, depth: number): string {
    const indent = depth * 18;
    if (entry.kind === "directory") {
      const open = this.expanded.has(entry.path ?? "");
      return `<div class="tree-row tree-dir ${open ? "open" : ""}" role="treeitem" aria-expanded="${open}" tabindex="0" data-tree-dir="${escapeHtml(entry.path ?? "")}" style="--depth:${indent}px"><button class="tree-toggle" data-tree-toggle="${escapeHtml(entry.path ?? "")}" aria-label="展开文件夹">${open ? "▾" : "▸"}</button><span class="folder-file-kind">DIR</span><strong>${escapeHtml(entry.name)}</strong><small>文件夹${entry.size ? ` · ${entry.size} 项` : ""}</small></div>`;
    }
    const disabled = entry.path ? "" : " tree-file-static";
    return `<div class="tree-row tree-file${disabled}" role="treeitem" tabindex="0" data-tree-file="${escapeHtml(entry.path ?? "")}" style="--depth:${indent}px"><span class="tree-spacer"></span><span class="folder-file-kind">${escapeHtml(kindBadge(entry))}</span><strong>${escapeHtml(entry.name)}</strong><small>${formatBytes(entry.size)} · ${escapeHtml(formatDate(entry.modified))}${entry.path ? "" : " · 预览仅限 App"}</small><i class="tree-open-hint">↗</i></div>`;
  }

  private async toggleDir(path: string) {
    if (this.expanded.has(path)) {
      this.expanded.delete(path);
      this.renderTree();
      return;
    }
    this.expanded.add(path);
    if (!this.children.has(path)) {
      try {
        const entries = (await listDir(path)).map(entryToFolderEntry);
        this.children.set(path, entries);
      } catch (error) {
        this.expanded.delete(path);
        this.options.notify(error instanceof Error ? error.message : "读取文件夹失败");
      }
    }
    this.renderTree();
  }

  private onClick(event: MouseEvent) {
    const target = event.target as HTMLElement;
    const toggle = target.closest<HTMLElement>("[data-tree-toggle]");
    if (toggle?.dataset.treeToggle) {
      void this.toggleDir(toggle.dataset.treeToggle);
      return;
    }
    const dirRow = target.closest<HTMLElement>("[data-tree-dir]");
    if (dirRow?.dataset.treeDir) {
      void this.toggleDir(dirRow.dataset.treeDir);
      return;
    }
    const fileRow = target.closest<HTMLElement>("[data-tree-file]");
    if (!fileRow) return;
    const path = fileRow.dataset.treeFile;
    if (!path) {
      this.options.notify("文件预览与打开仅在 RhineLab.app 内可用");
      return;
    }
    const name = fileRow.querySelector("strong")?.textContent ?? path;
    void this.openPreview(path, name);
  }

  private onKeydown(event: KeyboardEvent) {
    if (!this.isPreviewOpen) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.closePreview();
    }
  }

  // ---------- 预览面板 ----------

  async openPreview(path: string, name: string) {
    if (!(await detectNative())) {
      this.options.notify("文件预览仅在 RhineLab.app 内可用");
      return;
    }
    this.previewEntry = { name, kind: "file", size: 0, modified: 0, extension: "", relativePath: path, path };
    this.previewKindValue = previewKind(name);
    const $name = this.$("#preview-name");
    const $path = this.$("#preview-path");
    const $body = this.$("#preview-body");
    const $ui = this.$("#preview-ui");
    $name.textContent = name;
    $path.textContent = path.startsWith("/")
      ? path
      : `~/Documents/${path}`;
    $ui.hidden = false;
    $ui.classList.remove("preview-loaded", "preview-error");
    document.body.classList.add("preview-open");
    await this.renderPreview($body, path, name);
  }

  private async renderPreview(
    body: HTMLElement,
    path: string,
    name: string,
  ) {
    const kind = this.previewKindValue;
    if (kind === "image") {
      body.innerHTML = `<img class="preview-media" src="${fileUrl(path)}" alt="${escapeHtml(name)}"/>`;
    } else if (kind === "pdf") {
      body.innerHTML = `<iframe class="preview-frame" src="${fileUrl(path)}" title="${escapeHtml(name)}"></iframe>`;
    } else if (kind === "video") {
      body.innerHTML = `<video class="preview-media" src="${fileUrl(path)}" controls></video>`;
    } else if (kind === "audio") {
      body.innerHTML = `<div class="preview-audio"><div class="preview-audio-mark">◉</div><div class="preview-audio-name">${escapeHtml(name)}</div><audio controls src="${fileUrl(path)}"></audio></div>`;
    } else if (kind === "text") {
      body.innerHTML = `<div class="preview-loading">READING FILE…</div>`;
      try {
        const result = await readText(path);
        const pre = document.createElement("pre");
        pre.className = "preview-text";
        pre.textContent = result.text;
        let html = "";
        if (result.truncated) {
          html += `<div class="preview-truncated">文件较大，仅显示前 ${formatBytes(result.bytes)}（已截断）。可用默认应用打开完整内容。</div>`;
        }
        body.innerHTML = html;
        body.appendChild(pre);
      } catch (error) {
        body.innerHTML = this.errorMarkup(error);
      }
    } else if (kind === "office") {
      body.innerHTML = `<div class="preview-loading">CONVERTING DOCUMENT…<small>首次转换可能需要几秒</small></div>`;
      try {
        const result: ConvertResult = await convertOffice(path);
        if (result.ok && result.fileUrl) {
          body.innerHTML = `<iframe class="preview-frame" src="${result.fileUrl}" title="${escapeHtml(name)}"></iframe>`;
          this.options.notify(
            result.pages ? `文档已转换：共 ${result.pages} 页` : "文档已转换",
          );
        } else if (result.html) {
          body.innerHTML = `<div class="preview-doc-html">${result.html}</div>`;
          this.options.notify("已按文本模式显示（无法精确还原排版）");
        } else {
          throw new Error(result.error || "该文档无法转换为可预览格式");
        }
      } catch (error) {
        body.innerHTML = this.errorMarkup(error);
      }
    } else {
      body.innerHTML = `<div class="preview-fallback"><img src="${thumbUrl(path)}" alt="预览" onerror="this.remove()"/><div class="preview-fallback-note">该格式暂不支持内嵌预览，可使用默认应用打开。</div></div>`;
    }
  }

  private errorMarkup(error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    return `<div class="preview-error-state"><strong>PREVIEW UNAVAILABLE</strong><p>${escapeHtml(message)}</p></div>`;
  }

  closePreview() {
    if (!this.previewEntry) return;
    this.previewEntry = null;
    const $ui = this.$("#preview-ui");
    $ui.hidden = true;
    this.$("#preview-body").innerHTML = "";
    document.body.classList.remove("preview-open");
  }

  // ---------- 面板操作按钮 ----------

  handleAction(action: string) {
    const path = this.previewEntry?.path;
    if (!path) return false;
    if (action === "preview-close") {
      this.closePreview();
      return true;
    }
    if (action === "preview-open") {
      void openWithDefaultApp(path);
      this.options.notify("已交给默认应用打开");
      return true;
    }
    if (action === "preview-reveal") {
      void revealInFinder(path);
      this.options.notify("已在 Finder 中定位");
      return true;
    }
    return false;
  }
}
