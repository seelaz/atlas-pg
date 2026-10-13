# atlas-pg

Prefixo portátil de PostgreSQL 17.9 com pgvector 0.8.7.

O arquivo publicado no release é só o servidor: `bin`, `lib` e `share`. Não tem pgAdmin, não tem serviço e não tem launcher. Quem sobe o banco é o launcher do repositório da API: `pg.ps1` no Windows e `pg.sh` no Linux.

| Sistema | Arquivo | Release |
|---|---|---|
| Windows x64 | `atlas-pg-win-x64.zip` | v0.1.0 |
| Linux x64 | `atlas-pg-linux-x64.tar.gz` | v0.2.0 |

O binário Linux não é estático. `CREATE EXTENSION` precisa carregar `.so`. A libc e o carregador vêm da máquina. O resto fica em `lib/`, com RPATH `$ORIGIN`. O piso é glibc 2.28.

## Versões

| Peça | Versão | Origem |
|---|---|---|
| PostgreSQL | 17.9 | Windows: binários da EDB, `postgresql-17.9-2-windows-x64-binaries.zip`. Linux: fonte `postgresql-17.9.tar.bz2`, com OpenSSL 3.0.16 no prefixo |
| pgvector | 0.8.7 | tag `v0.8.7`, compilado contra esse prefixo |
| glibc | 2.28 | piso do binário Linux; a libc vem da máquina |

As extensões do próprio PostgreSQL que o baseline do Atlas pede ficam no prefixo: `unaccent` 1.1, `postgres_fdw` 1.1, `pgcrypto` 1.3, `pg_trgm` 1.6 e `btree_gist` 1.7.

## Gerar de novo

Windows, numa máquina com Visual Studio 2022 (ferramentas C++ x64) e PowerShell 7:

```powershell
pwsh -File .\build.ps1
```

O zip sai em `dist/atlas-pg-win-x64.zip`.

Linux, com o Docker no ar. A compilação roda dentro de `quay.io/pypa/manylinux_2_28_x86_64` e o prefixo é montado só no fim:

```powershell
pwsh -File .\build-linux.ps1
```

O tar sai em `dist/atlas-pg-linux-x64.tar.gz`. Os dois scripts imprimem o SHA-256. Esses arquivos não entram no git: o release do GitHub é a distribuição.

PostgreSQL e pgvector usam a PostgreSQL License.
