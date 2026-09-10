import { useCallback, useRef, useState } from 'react';
import {
  X,
  Upload,
  Download,
  Loader2,
  AlertCircle,
  CheckCircle,
  FileText,
  FileUp,
} from 'lucide-react';
import type { Difficulty, QuestionCategory, BulkUploadRow, BulkUploadError } from '@/types';
import { api } from '@/services/api';

const CATEGORIES: QuestionCategory[] = [
  'General Knowledge',
  'Science',
  'Technology',
  'Sports',
  'History',
  'Geography',
  'Entertainment',
  'Logic',
];
const DIFFICULTIES: Difficulty[] = ['easy', 'medium', 'hard'];
const VALID_CATEGORIES = new Set(CATEGORIES);
const VALID_DIFFICULTIES = new Set(DIFFICULTIES);

const CSV_TEMPLATE = `question,option_a,option_b,option_c,option_d,correct_answer,category,difficulty,active
What is the capital of France?,Berlin,Madrid,Paris,Rome,C,Geography,easy,true
What is 7 x 8?,54,56,64,48,B,Science,easy,true`;

type Phase = 'idle' | 'parsing' | 'preview' | 'importing' | 'done';

interface ParsedRow {
  rowNumber: number;
  data: BulkUploadRow;
  error: string | null;
}

function downloadTemplate() {
  const blob = new Blob([CSV_TEMPLATE], { type: 'text/csv' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'questions_template.csv';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

function splitCSVLine(line: string): string[] {
  const result: string[] = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch === ',' && !inQuotes) {
      result.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  result.push(current);
  return result;
}

function parseCSV(text: string): ParsedRow[] {
  const lines: string[] = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === '"') {
      inQuotes = !inQuotes;
      current += ch;
    } else if (ch === '\n' && !inQuotes) {
      lines.push(current);
      current = '';
    } else if (ch === '\r' && !inQuotes) {
      // skip carriage return
    } else {
      current += ch;
    }
  }
  if (current.trim()) lines.push(current);

  if (lines.length < 2) return [];

  const headers = splitCSVLine(lines[0]).map((h) => h.trim().toLowerCase());

  const required = [
    'question', 'option_a', 'option_b', 'option_c', 'option_d',
    'correct_answer', 'category', 'difficulty', 'active',
  ];
  for (const req of required) {
    if (!headers.includes(req)) {
      throw new Error(
        `Missing required column: "${req}". Expected columns: ${required.join(', ')}`
      );
    }
  }

  const colIndex: Record<string, number> = {};
  headers.forEach((h, i) => { colIndex[h] = i; });

  const rows: ParsedRow[] = [];

  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    const cols = splitCSVLine(line);
    const data: BulkUploadRow = {
      question: (cols[colIndex['question']] ?? '').trim(),
      option_a: (cols[colIndex['option_a']] ?? '').trim(),
      option_b: (cols[colIndex['option_b']] ?? '').trim(),
      option_c: (cols[colIndex['option_c']] ?? '').trim(),
      option_d: (cols[colIndex['option_d']] ?? '').trim(),
      correct_answer: (cols[colIndex['correct_answer']] ?? '').trim(),
      category: (cols[colIndex['category']] ?? '').trim(),
      difficulty: (cols[colIndex['difficulty']] ?? '').trim(),
      active: (cols[colIndex['active']] ?? '').trim(),
    };

    const error = validateRow(data);
    rows.push({ rowNumber: i + 1, data, error });
  }

  return rows;
}

function validateRow(data: BulkUploadRow): string | null {
  if (!data.question || data.question.length < 4) {
    return 'Question text must be at least 4 characters.';
  }
  if (data.question.length > 300) {
    return 'Question text must be 300 characters or fewer.';
  }
  if (!data.option_a || !data.option_b || !data.option_c || !data.option_d) {
    return 'All four options must be filled in.';
  }
  const lowered = [
    data.option_a.toLowerCase(),
    data.option_b.toLowerCase(),
    data.option_c.toLowerCase(),
    data.option_d.toLowerCase(),
  ];
  if (new Set(lowered).size !== 4) {
    return 'Two or more options are identical.';
  }
  const ca = data.correct_answer.toUpperCase();
  let correctNum: number;
  if (ca === 'A') correctNum = 0;
  else if (ca === 'B') correctNum = 1;
  else if (ca === 'C') correctNum = 2;
  else if (ca === 'D') correctNum = 3;
  else {
    const n = parseInt(ca, 10);
    if (isNaN(n) || n < 0 || n > 3) {
      return 'Correct answer must be A, B, C, D (or 0, 1, 2, 3).';
    }
    correctNum = n;
  }
  if (!VALID_CATEGORIES.has(data.category as QuestionCategory)) {
    return `Invalid category: "${data.category}". Valid: ${CATEGORIES.join(', ')}`;
  }
  if (!VALID_DIFFICULTIES.has(data.difficulty as Difficulty)) {
    return `Invalid difficulty: "${data.difficulty}". Valid: easy, medium, hard`;
  }
  const activeLower = data.active.toLowerCase();
  if (
    activeLower !== 'true' &&
    activeLower !== 'false' &&
    activeLower !== '1' &&
    activeLower !== '0' &&
    activeLower !== 'yes' &&
    activeLower !== 'no'
  ) {
    return 'Active must be true or false.';
  }
  return null;
}

function parseCorrectAnswer(val: string): number {
  const ca = val.toUpperCase();
  if (ca === 'A') return 0;
  if (ca === 'B') return 1;
  if (ca === 'C') return 2;
  if (ca === 'D') return 3;
  return parseInt(ca, 10) || 0;
}

function parseActive(val: string): boolean {
  const v = val.toLowerCase();
  return v === 'true' || v === '1' || v === 'yes';
}

export function BulkUploadQuestions({
  open,
  onClose,
  onImported,
}: {
  open: boolean;
  onClose: () => void;
  onImported: () => void;
}) {
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [phase, setPhase] = useState<Phase>('idle');
  const [parsedRows, setParsedRows] = useState<ParsedRow[]>([]);
  const [parseError, setParseError] = useState('');
  const [fileName, setFileName] = useState('');
  const [importResult, setImportResult] = useState<{
    imported: number;
    skipped: number;
    errors: BulkUploadError[];
  } | null>(null);
  const [progress, setProgress] = useState({ current: 0, total: 0 });

  const validRows = parsedRows.filter((r) => !r.error);
  const invalidRows = parsedRows.filter((r) => r.error);

  const reset = useCallback(() => {
    setPhase('idle');
    setParsedRows([]);
    setParseError('');
    setFileName('');
    setImportResult(null);
    setProgress({ current: 0, total: 0 });
  }, []);

  const handleClose = () => {
    reset();
    onClose();
  };

  const handleFile = useCallback(async (file: File) => {
    setPhase('parsing');
    setParseError('');
    setParsedRows([]);
    setImportResult(null);
    setFileName(file.name);

    try {
      const text = await file.text();
      const rows = parseCSV(text);
      if (rows.length === 0) {
        setParseError('The CSV file is empty or has no data rows.');
        setPhase('idle');
        return;
      }
      setParsedRows(rows);
      setPhase('preview');
    } catch (err) {
      setParseError(
        err instanceof Error
          ? err.message
          : 'Could not parse the CSV file. Please check the format.'
      );
      setPhase('idle');
    }
  }, []);

  const handleImport = useCallback(async () => {
    if (validRows.length === 0) return;

    setPhase('importing');
    setProgress({ current: 0, total: validRows.length });

    try {
      const payload = validRows.map((r) => ({
        question: r.data.question,
        option_a: r.data.option_a,
        option_b: r.data.option_b,
        option_c: r.data.option_c,
        option_d: r.data.option_d,
        correct_answer: parseCorrectAnswer(r.data.correct_answer),
        category: r.data.category,
        difficulty: r.data.difficulty,
        is_active: parseActive(r.data.active),
      }));

      const result = await api.bulkCreateQuestions(payload);

      setImportResult({
        imported: result.importedCount,
        skipped: result.skippedCount,
        errors: result.errors,
      });
      setProgress({ current: payload.length, total: payload.length });
      setPhase('done');
      onImported();
    } catch (err) {
      setParseError(
        err instanceof Error
          ? err.message
          : 'Import failed. Please try again.'
      );
      setPhase('preview');
    }
  }, [validRows, onImported]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-ink-950/50 p-0 backdrop-blur-sm sm:items-center sm:p-4 animate-fade-in">
      <div className="card w-full max-w-3xl max-h-[92vh] overflow-y-auto rounded-b-none sm:rounded-2xl animate-slide-up">
        {/* Header */}
        <div className="sticky top-0 z-10 flex items-center justify-between border-b border-ink-200 bg-white px-5 py-4 dark:border-ink-800 dark:bg-ink-900">
          <h2 className="font-display text-lg font-bold flex items-center gap-2">
            <FileUp size={20} /> Bulk Upload Questions
          </h2>
          <button
            onClick={handleClose}
            className="btn-ghost h-9 w-9 !p-0"
            aria-label="Close"
          >
            <X size={18} />
          </button>
        </div>

        <div className="p-5 space-y-5">
          {/* Parse error */}
          {parseError && (
            <div className="flex items-start gap-2 rounded-xl bg-error-500/10 px-4 py-3 text-sm font-medium text-error-600 dark:text-error-400 animate-fade-in">
              <AlertCircle size={16} className="mt-0.5 shrink-0" />
              <span>{parseError}</span>
            </div>
          )}

          {/* Idle / file selection */}
          {(phase === 'idle' || phase === 'parsing') && (
            <div className="space-y-4">
              <div
                onClick={() => fileInputRef.current?.click()}
                className="flex cursor-pointer flex-col items-center gap-3 rounded-2xl border-2 border-dashed border-ink-300 p-8 text-center transition-colors hover:border-primary-500 dark:border-ink-700 dark:hover:border-primary-500"
              >
                {phase === 'parsing' ? (
                  <Loader2 size={32} className="animate-spin text-primary-500" />
                ) : (
                  <div className="grid h-14 w-14 place-items-center rounded-2xl bg-primary-500/10 text-primary-500">
                    <Upload size={26} />
                  </div>
                )}
                <div>
                  <p className="font-display text-base font-bold">
                    {phase === 'parsing' ? 'Parsing CSV…' : 'Click to select a CSV file'}
                  </p>
                  <p className="mt-1 text-xs text-ink-500 dark:text-ink-400">
                    Upload a CSV file with your questions. Hundreds or thousands at once.
                  </p>
                </div>
              </div>
              <input
                ref={fileInputRef}
                type="file"
                accept=".csv,text/csv"
                className="hidden"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) void handleFile(file);
                  e.target.value = '';
                }}
              />
              <button
                onClick={downloadTemplate}
                className="btn-outline w-full"
              >
                <Download size={16} /> Download CSV Template
              </button>

              {/* Format help */}
              <div className="rounded-xl border border-ink-200 bg-ink-50 p-4 dark:border-ink-800 dark:bg-ink-950">
                <p className="mb-2 flex items-center gap-1.5 text-xs font-bold text-ink-500 dark:text-ink-400">
                  <FileText size={14} /> CSV Format
                </p>
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b border-ink-200 dark:border-ink-800">
                        <th className="py-1.5 pr-3 text-left font-semibold">Column</th>
                        <th className="py-1.5 pr-3 text-left font-semibold">Required</th>
                        <th className="py-1.5 text-left font-semibold">Description</th>
                      </tr>
                    </thead>
                    <tbody className="text-ink-500 dark:text-ink-400">
                      <tr><td className="py-1 pr-3 font-mono">question</td><td className="pr-3">Yes</td><td>Question text (4–300 chars)</td></tr>
                      <tr><td className="py-1 pr-3 font-mono">option_a</td><td className="pr-3">Yes</td><td>Answer option A</td></tr>
                      <tr><td className="py-1 pr-3 font-mono">option_b</td><td className="pr-3">Yes</td><td>Answer option B</td></tr>
                      <tr><td className="py-1 pr-3 font-mono">option_c</td><td className="pr-3">Yes</td><td>Answer option C</td></tr>
                      <tr><td className="py-1 pr-3 font-mono">option_d</td><td className="pr-3">Yes</td><td>Answer option D</td></tr>
                      <tr><td className="py-1 pr-3 font-mono">correct_answer</td><td className="pr-3">Yes</td><td>A, B, C, D or 0, 1, 2, 3</td></tr>
                      <tr><td className="py-1 pr-3 font-mono">category</td><td className="pr-3">Yes</td><td>{CATEGORIES.join(', ')}</td></tr>
                      <tr><td className="py-1 pr-3 font-mono">difficulty</td><td className="pr-3">Yes</td><td>easy, medium, hard</td></tr>
                      <tr><td className="py-1 font-mono">active</td><td>Yes</td><td>true or false</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          )}

          {/* Preview */}
          {phase === 'preview' && (
            <div className="space-y-4">
              <div className="flex items-center gap-2 text-sm">
                <FileText size={16} className="text-ink-400" />
                <span className="font-medium">{fileName}</span>
              </div>

              {/* Summary */}
              <div className="grid grid-cols-3 gap-3">
                <div className="card p-3 text-center">
                  <p className="font-display text-2xl font-extrabold">{parsedRows.length}</p>
                  <p className="text-xs font-medium text-ink-500 dark:text-ink-400">Total Rows</p>
                </div>
                <div className="card p-3 text-center">
                  <p className="font-display text-2xl font-extrabold text-success-500">{validRows.length}</p>
                  <p className="text-xs font-medium text-ink-500 dark:text-ink-400">Valid</p>
                </div>
                <div className="card p-3 text-center">
                  <p className="font-display text-2xl font-extrabold text-error-500">{invalidRows.length}</p>
                  <p className="text-xs font-medium text-ink-500 dark:text-ink-400">Invalid</p>
                </div>
              </div>

              {/* Invalid rows */}
              {invalidRows.length > 0 && (
                <div>
                  <h3 className="mb-2 text-sm font-bold text-error-600 dark:text-error-400">
                    Invalid Rows ({invalidRows.length})
                  </h3>
                  <div className="max-h-48 overflow-y-auto rounded-xl border border-error-200 dark:border-error-800">
                    <div className="divide-y divide-error-100 dark:divide-error-900">
                      {invalidRows.slice(0, 100).map((r) => (
                        <div key={r.rowNumber} className="flex items-start gap-2 px-3 py-2 text-xs">
                          <span className="shrink-0 font-bold text-error-500">Row {r.rowNumber}</span>
                          <span className="text-ink-500 dark:text-ink-400">{r.error}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                  {invalidRows.length > 100 && (
                    <p className="mt-1 text-xs text-ink-400">
                      Showing first 100 errors. {invalidRows.length - 100} more…
                    </p>
                  )}
                </div>
              )}

              {/* Valid rows preview */}
              {validRows.length > 0 && (
                <div>
                  <h3 className="mb-2 text-sm font-bold text-success-600 dark:text-success-400">
                    Valid Questions ({validRows.length}) — Preview
                  </h3>
                  <div className="max-h-48 overflow-y-auto rounded-xl border border-ink-200 dark:border-ink-800">
                    <div className="divide-y divide-ink-100 dark:divide-ink-800">
                      {validRows.slice(0, 20).map((r) => (
                        <div key={r.rowNumber} className="px-3 py-2 text-xs">
                          <p className="font-medium truncate">{r.data.question}</p>
                          <p className="text-ink-400">
                            Answer: {r.data.correct_answer.toUpperCase()} · {r.data.category} · {r.data.difficulty}
                          </p>
                        </div>
                      ))}
                    </div>
                  </div>
                  {validRows.length > 20 && (
                    <p className="mt-1 text-xs text-ink-400">
                      Showing first 20 of {validRows.length} valid questions.
                    </p>
                  )}
                </div>
              )}

              {/* Actions */}
              <div className="flex items-center gap-2 pt-1">
                <button onClick={reset} className="btn-ghost">
                  Choose another file
                </button>
                <div className="flex-1" />
                <button onClick={handleClose} className="btn-ghost">
                  Cancel
                </button>
                <button
                  onClick={handleImport}
                  disabled={validRows.length === 0}
                  className="btn-primary"
                >
                  <Upload size={18} />
                  Import {validRows.length} question{validRows.length === 1 ? '' : 's'}
                </button>
              </div>
            </div>
          )}

          {/* Importing progress */}
          {phase === 'importing' && (
            <div className="flex flex-col items-center gap-4 py-8 text-center">
              <Loader2 size={36} className="animate-spin text-primary-500" />
              <div>
                <p className="font-display text-base font-bold">Importing questions…</p>
                <p className="mt-1 text-sm text-ink-500 dark:text-ink-400">
                  {progress.current} / {progress.total} processed
                </p>
              </div>
              <div className="w-full max-w-sm">
                <div className="h-2.5 w-full overflow-hidden rounded-full bg-ink-200 dark:bg-ink-800">
                  <div
                    className="h-full rounded-full bg-gradient-to-r from-primary-500 to-primary-400 transition-all duration-300"
                    style={{
                      width: `${progress.total > 0 ? Math.round((progress.current / progress.total) * 100) : 0}%`,
                    }}
                  />
                </div>
              </div>
            </div>
          )}

          {/* Done */}
          {phase === 'done' && importResult && (
            <div className="space-y-4">
              <div className="flex flex-col items-center gap-3 py-6 text-center animate-pop-in">
                <div className="grid h-14 w-14 place-items-center rounded-full bg-success-500/15 text-success-500">
                  <CheckCircle size={28} />
                </div>
                <h3 className="font-display text-lg font-bold">Import Complete</h3>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="card p-4 text-center">
                  <p className="font-display text-3xl font-extrabold text-success-500">
                    {importResult.imported}
                  </p>
                  <p className="text-xs font-medium text-ink-500 dark:text-ink-400">
                    Successfully Imported
                  </p>
                </div>
                <div className="card p-4 text-center">
                  <p className="font-display text-3xl font-extrabold text-error-500">
                    {importResult.skipped}
                  </p>
                  <p className="text-xs font-medium text-ink-500 dark:text-ink-400">
                    Failed / Skipped
                  </p>
                </div>
              </div>

              {importResult.errors.length > 0 && (
                <div>
                  <h3 className="mb-2 text-sm font-bold text-error-600 dark:text-error-400">
                    Errors ({importResult.errors.length})
                  </h3>
                  <div className="max-h-48 overflow-y-auto rounded-xl border border-error-200 dark:border-error-800">
                    <div className="divide-y divide-error-100 dark:divide-error-900">
                      {importResult.errors.slice(0, 100).map((e, i) => (
                        <div key={i} className="flex items-start gap-2 px-3 py-2 text-xs">
                          <span className="shrink-0 font-bold text-error-500">Row {e.row}</span>
                          <span className="text-ink-500 dark:text-ink-400">{e.error}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                </div>
              )}

              <div className="flex items-center gap-2 pt-1">
                <button onClick={reset} className="btn-outline">
                  Upload another file
                </button>
                <div className="flex-1" />
                <button onClick={handleClose} className="btn-primary">
                  <CheckCircle size={18} /> Done
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
