import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  Executable
} from 'vscode-languageclient/node';
import * as path from 'path';

let client: LanguageClient;

export function startLsp(context: vscode.ExtensionContext) {
  // Assuming the zig build puts the binary in zig-out/bin/llts-lsp
  const command = path.resolve(context.extensionPath, 'bin/llts-lsp');

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

export function stopLsp(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}
