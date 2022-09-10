export const arrayHasOne = (array: any[], elements: any[]): boolean => {
    if (!array || !elements) return false;
    return array.some((element: any) => elements.includes(element));
};