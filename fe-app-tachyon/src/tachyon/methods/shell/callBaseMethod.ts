import { executeShellCommand } from '../../../helpers';
import { Tachyon } from '../../types';

interface CallBaseMethodOptions {
  allowNonZeroWithStdout?: boolean;
  timeout?: number;
}

export async function callBaseMethod<T>(
  method: Tachyon.AvailableMethods,
  args: string[] = [],
  command: string = '/usr/bin/tachyon',
  options: CallBaseMethodOptions = {},
): Promise<Tachyon.MethodResponse<T>> {
  try {
    const response = await executeShellCommand({
      command,
      args: [method as string, ...args],
      timeout: options.timeout ?? 15000,
    });
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
