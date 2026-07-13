import { execSync } from 'child_process';

export function getGitUser(defaultName = 'Forkop', defaultEmail = 'ushan0v@users.noreply.github.com') {
    try {
        const name = execSync('git config user.name', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
        const email = execSync('git config user.email', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();

        if (name) {
            return { name, email: email || defaultEmail };
        }
    } catch (error) {
        // Fall through
    }

    return {
        name: defaultName,
        email: defaultEmail,
    };
}
