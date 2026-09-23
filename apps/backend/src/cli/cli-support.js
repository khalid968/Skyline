import path from 'path';
import readline from 'readline';
import dotenv from 'dotenv';
import { Pool } from 'pg';
import configuration from '../config/configuration';
import { validateEnv } from '../config/validate-env';
import { AuditService } from '../modules/audit/audit.service';

// Shared plumbing for the operator command-line tools. They talk to Postgres
// directly (no HTTP server needed) but use the SAME validation, hashing and
// audit code as the server, so a code issued here redeems there.

export function loadConfig() {
  dotenv.config({
    path: path.join(__dirname, '..', '..', '.env'),
    quiet: true,
  });
  validateEnv(process.env);
  return configuration();
}

export function connect(config) {
  const pool = new Pool({ connectionString: config.database.url, max: 2 });
  const audit = new AuditService({
    query: (text, params) => pool.query(text, params),
  });
  return { pool, audit };
}

// --name value / --flag  ->  { name: 'value', flag: true }
export function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) out[key] = true;
    else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

// Reads one line without echoing it, for passwords. Consecutive calls share
// ONE input stream: at a terminal, one readline interface asks each question in
// turn; with piped input (scripts, tests), stdin is read once and handed out a
// line at a time. Creating a fresh interface per question can swallow buffered
// input and leave the second prompt waiting forever.
let terminal = null;
let pipedLines = null;

export async function askHidden(question) {
  if (!process.stdin.isTTY) {
    if (!pipedLines) {
      const chunks = [];
      for await (const chunk of process.stdin) chunks.push(chunk);
      pipedLines = Buffer.concat(chunks).toString('utf8').split(/\r?\n/);
    }
    process.stdout.write(`${question}\n`);
    return pipedLines.shift() ?? '';
  }

  if (!terminal) {
    terminal = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
      terminal: true,
    });
    terminal.muted = false;
    terminal._writeToOutput = (text) => {
      if (!terminal.muted) terminal.output.write(text);
    };
  }
  return new Promise((resolve) => {
    terminal.muted = false;
    terminal.question(question, (answer) => {
      terminal.muted = false;
      terminal.output.write('\n');
      resolve(answer);
    });
    terminal.muted = true; // the prompt is out; hide what is typed
  });
}

export function closePrompts() {
  if (terminal) terminal.close();
  terminal = null;
}

export async function run(main) {
  try {
    await main();
  } catch (err) {
    // Constraint names are useful to an operator at a terminal; they never
    // reach a network client from here.
    console.error(
      `\nFailed: ${err.message}${err.constraint ? ` (${err.constraint})` : ''}`,
    );
    process.exitCode = 1;
  } finally {
    closePrompts();
  }
}
