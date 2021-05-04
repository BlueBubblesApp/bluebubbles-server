import { Entity, Column, PrimaryGeneratedColumn, CreateDateColumn, UpdateDateColumn } from "typeorm";

@Entity({ name: "token" })
export class Token {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "name", nullable: false, default: "api-client" })
    name: string;

    @Column("varchar", { name: "type", nullable: false, default: "bearer" })
    type: string;

    @Column("text", { name: "access_token", nullable: false })
    accessToken: string;

    @Column("text", { name: "refresh_token", nullable: false })
    refreshToken: string;

    // Default expiration: 14 days
    @Column("integer", { name: "expires_in", nullable: false, default: 14 * 86400 })
    expiresIn: number;

    @CreateDateColumn()
    created: Date;

    @UpdateDateColumn()
    updated: Date;

    public isExpired(): boolean {
        const now = new Date().getTime();
        const created = this.created.getTime();
        return now > created + this.expiresIn * 1000;
    }
}
