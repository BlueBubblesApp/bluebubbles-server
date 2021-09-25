export const BadRequest = ({ message = "Validation Error", errors = [] }: { message: string; errors: string[] }) => {
    return { status: 400, message, errors };
};
