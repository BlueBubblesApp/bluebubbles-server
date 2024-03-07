const singletons = new Map<string, Promise<any>>();

export const AsyncSingleton = <T extends (...args: any[]) => any>(name: string): MethodDecorator => {
    return (_target: any, _propertyKey: string | symbol, descriptor: PropertyDescriptor) => {
        const originalMethod = descriptor.value;

        descriptor.value = async function (...args: any[]): Promise<ReturnType<T>> {
            const executor = singletons.get(name);
            if (executor) return await executor;

            const promise = originalMethod.apply(this, args);
            singletons.set(name, promise);

            try {
                const result = await promise;
                singletons.delete(name);
                return result;
            } catch (ex) {
                singletons.delete(name);
                throw ex;
            }
        };

        return descriptor;
    };
};
