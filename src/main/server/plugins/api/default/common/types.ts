export type PasswordAuthBody = {
    password: string;
    name?: string;
};

export type RefreshAuthBody = {
    token: string;
};
