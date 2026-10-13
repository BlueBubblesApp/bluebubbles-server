const ARGUMENT_SEPARATION_REGEX = /([^=\s]+)=?\s*(.*)/;

export const ParseArguments = (argv: string[]) => {
    // Removing node/bin and called script name
    argv = argv.slice(1);

    const parsedArgs: Record<string, any> = {};
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        const argMatch = arg.match(ARGUMENT_SEPARATION_REGEX);
        argMatch.splice(0, 1);

        // Retrieve the argument name
        let argName = argMatch[0];

        // Make sure the arg has a "-" or "--". Otherwise it's a value.
        if (argName.indexOf("-") !== 0) continue;

        // Remove "--" or "-"
        argName = argName.slice(argName.slice(0, 2).lastIndexOf("-") + 1);

        // Try and parse the value
        // If the value is empty, check the next argument for a value
        let argValue: any = argMatch[1];
        if (argValue === "") {
            if (argv[i + 1] && argv[i + 1][0] !== "-") {
                argValue = argv[i + 1];
                i++;
            } else {
                argValue = true;
            }
        } else {
            argValue = parseFloat(arg[1]).toString() === arg[1] ? +arg[1] : arg[1];
        }

        // Normalize the value for true/false
        if (argValue === "true") argValue = true;
        if (argValue === "false") argValue = false;

        // Normalize the value for numbers
        if (typeof argValue === "string" && !isNaN(+argValue)) argValue = +argValue;

        // Add the argument to the parsed args
        parsedArgs[argName] = argValue;
    }

    return parsedArgs;
}
