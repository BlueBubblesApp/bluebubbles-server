export type SipsImageFormat = "jpeg" | "png";

type ShellCommandExecutor = (command: string) => Promise<string>;

export const convertImageWithSips = async (
    executeCommand: ShellCommandExecutor,
    originalPath: string,
    outputPath: string,
    format: SipsImageFormat
): Promise<void> => {
    const output = await executeCommand(
        `/usr/bin/sips --setProperty "format" "${format}" "${originalPath}" --out "${outputPath}"`
    );
    if (output?.includes("Error:")) {
        throw Error(`Failed to convert image to ${format.toUpperCase()}: ${output}`);
    }
};
