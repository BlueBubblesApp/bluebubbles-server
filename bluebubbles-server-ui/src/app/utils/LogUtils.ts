export const getLogType = (log: string) => {
    if (log.includes('[debug]')) return 'debug';
    if (log.includes('[warn]')) return 'warn';
    if (log.includes('[error]')) return 'error';
    return 'info';
};