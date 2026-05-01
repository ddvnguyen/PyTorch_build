import path from "node:path";
import { fileURLToPath } from "node:url";

const serverFile = fileURLToPath(import.meta.url);
const serverDir = path.dirname(serverFile);

export const repoRoot = process.cwd();
export const dataDir = path.join(repoRoot, ".pytorch-build-console");
export const cacheDir = path.join(dataDir, "cache");
export const runsDir = path.join(dataDir, "runs");
export const configPath = path.join(dataDir, "config.json");
export const envJsonPath = path.join(repoRoot, "src", "env.json");
export const clientDistPath = path.join(repoRoot, "dist", "client");
export const isBuiltServer = serverDir.includes(`${path.sep}dist${path.sep}server`);
