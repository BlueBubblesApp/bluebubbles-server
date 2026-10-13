export const arrayHasOne = (array: any[], elements: any[]): boolean => {
    if (!array || !elements) return false;
    array = array.map(i => i.toLowerCase());
    elements = elements.map(i => i.toLowerCase());
    return array.some((element: any) => elements.includes(element));
};
