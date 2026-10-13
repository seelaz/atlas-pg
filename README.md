# atlas-pg

Prefixo portátil de PostgreSQL 17.9 com pgvector 0.8.7 para Windows x64.

O zip publicado no release é só o servidor: `bin`, `lib` e `share`. Não tem pgAdmin, não tem serviço do Windows e não tem launcher. Quem sobe o banco é o `pg.ps1` do repositório da API.

## Versões

| Peça | Versão | Origem |
|---|---|---|
| PostgreSQL | 17.9 | binários sem instalador da EDB, `postgresql-17.9-2-windows-x64-binaries.zip` |
| pgvector | 0.8.7 | tag `v0.8.7`, compilado contra esse prefixo |

As extensões do próprio PostgreSQL que o baseline do Atlas pede ficam no prefixo: `unaccent` 1.1, `postgres_fdw` 1.1, `pgcrypto` 1.3, `pg_trgm` 1.6 e `btree_gist` 1.7.

## Gerar de novo

Numa máquina com Visual Studio 2022 (ferramentas C++ x64) e PowerShell 7:

```powershell
pwsh -File .\build.ps1
```

O zip sai em `dist/atlas-pg-win-x64.zip`. O script imprime o SHA-256. Esse arquivo não entra no git: o release do GitHub é a distribuição.

PostgreSQL e pgvector usam a PostgreSQL License.
