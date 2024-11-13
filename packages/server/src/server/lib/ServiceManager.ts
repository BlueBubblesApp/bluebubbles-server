import { Loggable } from "./logging/Loggable";

interface Service {
    start(): Promise<void>;
    stop(): Promise<void>;
}

export class ServiceManager extends Loggable {
    tag = "ServiceManager";

    private services: Map<string, Service> = new Map();
    private dependencies: Map<string, string[]> = new Map();

    registerService(name: string, service: Service, dependencies: string[] = []) {
        this.services.set(name, service);
        this.dependencies.set(name, dependencies);
    }

    async startServices() {
        const startedServices = new Set<string>();

        for (const [name, service] of this.services) {
            await this.startService(name, service, startedServices);
        }
    }

    private async startService(name: string, service: Service, startedServices: Set<string>) {
        if (startedServices.has(name)) return;

        const dependencies = this.dependencies.get(name) || [];
        for (const dependency of dependencies) {
            const dependencyService = this.services.get(dependency);
            if (dependencyService) {
                await this.startService(dependency, dependencyService, startedServices);
            }
        }

        this.log.info(`Starting service: ${name}`);
        await service.start();
        startedServices.add(name);
    }

    async stopServices() {
        const stoppedServices = new Set<string>();

        for (const [name, service] of Array.from(this.services).reverse()) {
            await this.stopService(name, service, stoppedServices);
        }
    }

    private async stopService(name: string, service: Service, stoppedServices: Set<string>) {
        if (stoppedServices.has(name)) return;

        this.log.info(`Stopping service: ${name}`);
        await service.stop();
        stoppedServices.add(name);
    }
}
