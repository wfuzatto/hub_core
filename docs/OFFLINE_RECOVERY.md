# Recuperação offline do HUB Core

## Regra arquitetural

O sistema não pode depender de disponibilidade futura de GitHub, Docker Hub, npm, PyPI, APT ou URLs externas de modelos para continuar operando.

As imagens Docker de produção/homologação são tratadas como artefatos completos de runtime: bibliotecas, interpretadores, pacotes nativos, módulos Python/Node e modelos necessários à execução devem estar dentro das imagens finais.

O projeto também mantém um bundle offline contendo:

- código-fonte completo do HUB e módulos, incluindo repositórios `.git` locais;
- `.env` e `modules.list`;
- todas as imagens Docker necessárias ao stack;
- checksums SHA-256;
- metadados de commits e versões.

Esse bundle permite restaurar o stack com `docker compose up --no-build`, sem consultar registries ou repositórios externos.

## Criar o bundle

Depois de construir e testar a versão aprovada:

```bash
cd /home/luisnasc/hub_core
chmod +x scripts/*.sh
./scripts/create_offline_bundle.sh
```

O resultado ficará em:

```text
offline-bundles/YYYYMMDD_HHMMSS/
```

O script aborta se alguma imagem exigida pelo Compose não estiver presente localmente. Isso é intencional: um bundle parcial não é considerado recuperação válida.

## O que o bundle protege

Depois de criado, a recuperação da versão capturada não depende de:

- GitHub;
- Docker Hub ou outro registry;
- npm registry;
- PyPI;
- mirrors Debian/APT;
- OpenCV Zoo/Git LFS;
- URLs externas usadas para obter modelos durante builds antigos.

O arquivo `docker-images.tar.gz` contém as imagens finais já construídas. Portanto, não é necessário reinstalar as dependências individualmente durante a restauração.

## Restaurar

Em um host com Docker Engine + Docker Compose já instalados:

```bash
chmod +x scripts/restore_offline_bundle.sh
./scripts/restore_offline_bundle.sh /caminho/do/offline-bundle /home/luisnasc/hub_core
```

O restore:

1. valida os SHA-256;
2. executa `docker load` das imagens salvas;
3. restaura código e configuração;
4. sobe o stack usando `--no-build`.

## Cópias externas

O diretório `offline-bundles/` não deve ser a única cópia. Mantenha ao menos uma cópia fora do servidor principal, preferencialmente em armazenamento independente.

## Segurança

O bundle contém `.env` e, portanto, segredos operacionais. Os arquivos são criados com permissões restritas, mas o diretório de backup deve ser tratado como confidencial e criptografado quando armazenado fora do servidor.

## Dados persistentes

Este mecanismo preserva dependências, imagens e código. Os dados de negócio continuam sujeitos à política de backup do `scripts/backup.sh` (MySQL e dados persistentes do Totem). Para recuperação completa de desastre, mantenha tanto os backups de dados quanto o bundle offline da versão correspondente.

## Política para novas dependências

Qualquer novo serviço, modelo, biblioteca ou runtime adicionado ao HUB deve obedecer aos seguintes critérios antes de ser homologado:

1. nenhuma dependência pode ser baixada em runtime;
2. o container final deve iniciar e operar sem acesso à Internet;
3. modelos necessários devem estar presentes dentro da imagem final;
4. toda nova imagem deve aparecer em `docker compose config --images` ou estar associada aos containers do stack para ser capturada pelo bundle;
5. após alterações de dependências, deve ser gerado um novo bundle offline.
