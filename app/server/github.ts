import fs from "node:fs/promises";
import path from "node:path";
import type { BuildOption, VersionOption } from "./types.js";
import { cacheDir } from "./paths.js";
import { mergeBuildOptions, parseBuildOptionsFromSources } from "./buildOptions.js";

const owner = "pytorch";
const repo = "pytorch";
const apiBase = `https://api.github.com/repos/${owner}/${repo}`;
const rawBase = `https://raw.githubusercontent.com/${owner}/${repo}`;

async function cachedJson<T>(cacheName: string, url: string, ttlMs: number): Promise<T> {
  await fs.mkdir(cacheDir, { recursive: true });
  const file = path.join(cacheDir, cacheName);
  try {
    const stat = await fs.stat(file);
    if (Date.now() - stat.mtimeMs < ttlMs) {
      return JSON.parse(await fs.readFile(file, "utf8")) as T;
    }
  } catch {
    // Cache miss.
  }

  const response = await fetch(url, {
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "pytorch-build-console"
    }
  });
  if (!response.ok) throw new Error(`GitHub request failed: ${response.status} ${response.statusText}`);
  const data = (await response.json()) as T;
  await fs.writeFile(file, JSON.stringify(data, null, 2), "utf8");
  return data;
}

async function fetchRaw(ref: string, file: string): Promise<string> {
  const response = await fetch(`${rawBase}/${encodeURIComponent(ref)}/${file}`, {
    headers: { "User-Agent": "pytorch-build-console" }
  });
  if (!response.ok) return "";
  return response.text();
}

interface GitHubRelease {
  tag_name: string;
  name: string | null;
  published_at: string;
  draft: boolean;
  prerelease: boolean;
}

interface GitHubTag {
  name: string;
}

export async function loadVersions(): Promise<{
  releases: VersionOption[];
  tags: VersionOption[];
  defaultRef: string;
}> {
  const [releaseData, tagData] = await Promise.all([
    cachedJson<GitHubRelease[]>("releases.json", `${apiBase}/releases?per_page=30`, 60 * 60 * 1000),
    cachedJson<GitHubTag[]>("tags.json", `${apiBase}/tags?per_page=80`, 60 * 60 * 1000)
  ]);

  const releases = releaseData
    .filter((release) => !release.draft)
    .map((release, index) => ({
      name: release.name || release.tag_name,
      ref: release.tag_name,
      kind: "release" as const,
      publishedAt: release.published_at,
      isLatest: index === 0 && !release.prerelease
    }));

  const releaseRefs = new Set(releases.map((release) => release.ref));
  const tags = tagData
    .filter((tag) => !releaseRefs.has(tag.name))
    .map((tag) => ({ name: tag.name, ref: tag.name, kind: "tag" as const }));

  return {
    releases,
    tags,
    defaultRef: releases[0]?.ref ?? tags[0]?.ref ?? "main"
  };
}

export async function loadBuildOptions(ref: string): Promise<BuildOption[]> {
  const sources = await Promise.all([
    fetchRaw(ref, "setup.py"),
    fetchRaw(ref, "tools/setup_helpers/env.py"),
    fetchRaw(ref, "tools/setup_helpers/cmake.py"),
    fetchRaw(ref, "tools/setup_helpers/cuda.py")
  ]);

  return mergeBuildOptions(parseBuildOptionsFromSources(sources.filter(Boolean)));
}
