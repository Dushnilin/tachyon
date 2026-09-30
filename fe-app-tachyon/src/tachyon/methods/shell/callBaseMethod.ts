import { executeShellCommand } from '../../../helpers';
import { Tachyon } from '../../types';

interface CallBaseMethodOptions {
  allowNonZeroWithStdout?: boolean;
  timeout?: number;
}

// The executable is a constant, not a parameter. It used to be an optional
// argument that every caller happened to leave alone, which meant a copy of
// any call site could point the frontend at a different binary and nothing
// would complain.
const TACHYON_BIN = '/usr/bin/tachyon';
const TACHYON_READ_BIN = '/usr/bin/tachyon-read';

// rpcd grants the read role exec on tachyon-read and withholds the main binary,
// so a read-only LuCI account is denied here by policy rather than by a missing
// method. Nothing in the session tells the frontend which role it has, and the
// ACL is per-file, so the denial is the only signal available. Switching on it
// and remembering keeps the page working for read-only accounts instead of
// rendering empty, and costs write accounts nothing: their first call is allowed
// and never enters this path.
//
// The binary stays a literal in both branches so shellCommandSurface.test.ts
// still sees every executable this project runs. A variable here would silently
// step outside that guard.
let useReadBinary = false;

function isAccessDenied(response: { stdout: string; stderr: string }): boolean {
  const text = `${response.stderr} ${response.stdout}`.toLowerCase();
  return (
    text.includes('permission denied') ||
    text.includes('access denied') ||
    text.includes('not authorized') ||
    text.includes('unauthorized')
  );
}

export async function callBaseMethod<T>(
  method: Tachyon.AvailableMethods,
  args: string[] = [],
  options: CallBaseMethodOptions = {},
): Promise<Tachyon.MethodResponse<T>> {
  try {
    const callArgs = [method as string, ...args];
    const timeout = options.timeout ?? 15000;

    let response = useReadBinary
      ? await executeShellCommand({
          command: TACHYON_READ_BIN,
          args: callArgs,
          timeout,
        })
      : await executeShellCommand({
          command: TACHYON_BIN,
          args: callArgs,
          timeout,
        });

    if (!useReadBinary && isAccessDenied(response)) {
      useReadBinary = true;
      response = await executeShellCommand({
        command: TACHYON_READ_BIN,
        args: callArgs,
        timeout,
      });
    }

    const exitCode = response.code ?? 0;

    if (
      exitCode !== 0 &&
      !(options.allowNonZeroWithStdout && response.stdout)
    ) {
      return {
        success: false,
        error: response.stderr || response.stdout || '',
      };
    }

    if (response.stdout) {
      try {
        let text = response.stdout.trim();
        const jsonMatch = text.match(/(\{[\s\S]*\}|\[[\s\S]*\])/);
        if (jsonMatch) {
          text = jsonMatch[0];
        }
        return {
          success: true,
          data: JSON.parse(text) as T,
        };
      } catch (_e) {
        return {
          success: true,
          data: response.stdout as T,
        };
      }
    }

    return {
      success: false,
      error: response.stderr || '',
    };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : '',
    };
  }
}
