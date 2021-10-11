export type KoaNext = () => Promise<any>;
export type ImageQuality = "good" | "better" | "best";
export type UpdateResult = {
    available: boolean;
    current: string,
    metadata: {
        version: string;
        release_date: string;
        release_name: string;
        release_notes: any;
    };
};
