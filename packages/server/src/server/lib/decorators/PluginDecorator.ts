// import { resultRetryer } from "@server/helpers/utils";
// import { getLogger } from "../logging/Loggable";
// import { PluginRegistry } from "@server/globals";

// export const Plugin = <T extends (...args: any[]) => any>({
//     name,
//     displayName,
//     description,
//     version,
//     author,
//     dependencies,
//     optionalDependencies,
// }: {
//     name: string;
//     displayName: string;
//     description: string;
//     version: string;
//     author: string;
//     dependencies?: string[];
//     optionalDependencies?: string[];
// }): ClassDecorator => {
//     return (target: any) => {
//         const registry = PluginRegistry.getPlugin(name);
//         if (registry) throw new Error(`Plugin with name, '${name}' already exists!`);
//     };
// };
