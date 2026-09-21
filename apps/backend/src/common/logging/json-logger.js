import { redact } from './redact';

// Nest LoggerService that writes one JSON object per line to stdout/stderr.
// Structured output is what a log aggregator wants, and it makes redaction
// dependable: values are objects until the last moment, so the redactor sees
// keys, not a pre-flattened string.

const LEVELS = ['error', 'warn', 'log', 'debug', 'verbose'];

export class JsonLogger {
  constructor(level = 'log', sink = process) {
    this.level = level;
    this.sink = sink;
  }

  enabled(level) {
    if (this.level === 'silent') return false;
    return LEVELS.indexOf(level) <= LEVELS.indexOf(this.level);
  }

  write(level, message, context, extra) {
    if (!this.enabled(level)) return;

    const line = {
      time: new Date().toISOString(),
      level,
      context: context || undefined,
      // A string message is kept as-is; an object is redacted like any other field.
      message: typeof message === 'string' ? message : redact(message),
      ...(extra ? redact(extra) : {}),
    };

    const stream =
      level === 'error' || level === 'warn'
        ? this.sink.stderr
        : this.sink.stdout;
    stream.write(`${JSON.stringify(line)}\n`);
  }

  // Nest passes the context as the last string argument, and for errors a
  // stack trace before it.
  log(message, ...rest) {
    this.write('log', message, lastString(rest));
  }

  warn(message, ...rest) {
    this.write('warn', message, lastString(rest));
  }

  debug(message, ...rest) {
    this.write('debug', message, lastString(rest));
  }

  verbose(message, ...rest) {
    this.write('verbose', message, lastString(rest));
  }

  error(message, ...rest) {
    const context = lastString(rest);
    const stack =
      rest.length > 1 && typeof rest[0] === 'string' ? rest[0] : undefined;
    this.write('error', message, context, stack ? { stack } : undefined);
  }

  // Structured event helper for code that wants named fields, not a sentence.
  event(level, message, fields, context) {
    this.write(level, message, context, fields);
  }
}

function lastString(rest) {
  const last = rest[rest.length - 1];
  return typeof last === 'string' ? last : undefined;
}
