# Integrações externas

## Repositório da API

Responsabilidades:

1. executar `mvn clean verify`;
2. construir a imagem Docker;
4. publicar `oficina360-api:<git-sha>`;
5. iniciar o workflow `Deploy Aplicacao no EKS` deste repositório,
   informando a URI completa da imagem.

## Repositório da Lambda

Responsabilidades:

1. manter o código Java, `template.yaml` e workflow SAM;
2. ler os outputs da infraestrutura:
   - `rds_host`;
   - `lambda_security_group_id`;
   - `lambda_subnet_ids`;
3. publicar a saída `AuthApiUrl` da stack SAM;
4. destruir a stack SAM antes do `terraform destroy` da VPC.

## Ordem de deploy

1. Infrastructure Apply;
2. deploy da API;
3. deploy da Lambda no repositório próprio;
4. deploy do Kong;
5. deploy da observabilidade;
6. smoke tests.

## Ordem de destruição

1. destruir a stack SAM da Lambda no repositório próprio;
2. executar `destroy` em observabilidade;
3. executar `destroy` no Kong;
4. executar Infrastructure Destroy.
