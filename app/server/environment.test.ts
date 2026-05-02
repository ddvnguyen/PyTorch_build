import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { getMinicondaBootstrapSpec, resolveCondaInstallRoot } from "./environment.js";

test("Miniconda bootstrap spec targets Windows silently", () => {
  const spec = getMinicondaBootstrapSpec("win32", "x64");

  assert.equal(spec.filename, "Miniconda3-latest-Windows-x86_64.exe");
  assert.equal(spec.url, "https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe");
  assert.deepEqual(spec.installerArgs, []);
});

test("Miniconda bootstrap spec targets Linux with batch install args", () => {
  const spec = getMinicondaBootstrapSpec("linux", "x64");

  assert.equal(spec.filename, "Miniconda3-latest-Linux-x86_64.sh");
  assert.equal(spec.url, "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh");
  assert.deepEqual(spec.installerArgs, ["-b", "-p"]);
});

test("resolveCondaInstallRoot walks up from the executable path", () => {
  const root = resolveCondaInstallRoot(path.join("C:\\Users\\demo", "miniconda3", "Scripts", "conda.exe"));

  assert.equal(root, path.join("C:\\Users\\demo", "miniconda3"));
});
