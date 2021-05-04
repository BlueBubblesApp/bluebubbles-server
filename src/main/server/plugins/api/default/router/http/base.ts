export interface HttpRouterBase {
    name: string;
    serve(): Promise<void>;
}
