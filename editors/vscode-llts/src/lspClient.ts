import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  Executable
} from 'vscode-languageclient/node';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'path';

let client: LanguageClient | undefined;

/**
 * Resolve the llts-lsp binary to run, in priority order:
 *
 *  1. `llts.serverPath` setting (absolute, ~-prefixed, or workspace-relative)
 *  2. `<workspace>/zig-out/bin/llts-lsp` — the repo's own build output
 *  3. `<extension>/bin/llts-lsp` — binary bundled with the extension
 *
 * Returns the first candidate that exists on disk, or null (caller shows a
 * setup error). Relative paths are resolved against the first workspace
 * folder, falling back to the extension directory.
 */
export function resolveServerPath(context: vscode.ExtensionContext): string | null {
  const setting = vscode.workspace.getConfiguration('llts').get<string>('serverPath', '').trim();
  const workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;

  const candidates: string[] = [];
  if (setting) {
    const expanded = setting.startsWith('~') ? path.join(os.homedir(), setting.slice(1)) : setting;
    candidates.push(path.isAbsolute(expanded) ? expanded : path.resolve(workspaceRoot ?? context.extensionPath, expanded));
  }
  if (workspaceRoot) {
    candidates.push(path.join(workspaceRoot, 'zig-out', 'bin', 'llts-lsp'));
  }
  candidates.push(path.join(context.extensionPath, 'bin', 'llts-lsp'));

  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {
      // unreadable path — skip to the next candidate
    }
  }
  return null;
}

export function startLsp(context: vscode.ExtensionContext): void {
  const command = resolveServerPath(context);
  if (!command) {
    vscode.window.showErrorMessage(
      "LLTS language server not found. Run 'zig build' in the repo (creates zig-out/bin/llts-lsp), or set 'llts.serverPath' to the binary's location."
    );
    return;
  }

  const run: Executable = {
    command: command,
    options: {
      env: { ...process.env }
    }
  };

  const serverOptions: ServerOptions = {
    run,
    debug: run
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'llts' }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/.clientrc')
    }
  };

  client = new LanguageClient(
    'lltsLsp',
    'LLTS Language Server',
    serverOptions,
    clientOptions
  );

  client.start().catch((err: any) => {
    vscode.window.showErrorMessage(`Failed to start LLTS language server: ${err.message}. Make sure 'zig build' was run in the root folder.`);
  });
}

export function stopLsp(): Thenable<void> {
  if (!client) {
    return Promise.resolve();
  }
  return client.stop();
}
