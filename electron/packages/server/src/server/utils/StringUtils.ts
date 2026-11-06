export const obfuscatedHandle = (address: string): string => {
    if (!address) return "<No Handle>";

    // If the handle is less than 4 characters, just return it
    if (address.length < 4) return address;

    // If the handle is an email address, return the first 2 letters and the domain.
    // But replace the rest with *'s
    if (address.includes("@")) {
        const [user, domain] = address.split("@");
        return `${user.substring(0, 2)}${"*".repeat(user.length - 2)}@${domain}`;
    }

    // Otherwise, replace all but the last 4 characters with X's
    return address.substring(0, address.length - 4).replace(/[0-9]/g, "*") + address.substring(address.length - 4);
}