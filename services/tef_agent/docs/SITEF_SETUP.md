# CliSiTef / SiTef

O driver real permanece deliberadamente bloqueado nesta etapa. O agente não inventa assinatura de DLL nem baixa SDK de fonte não oficial.

Para habilitar o driver real serão necessários, fornecidos/homologados pela integradora TEF:

- biblioteca oficial CliSiTef compatível com o SO/arquitetura (`CliSiTef.dll` no Windows ou biblioteca equivalente suportada no Linux);
- dependências oficiais da biblioteca;
- identificação da empresa/estabelecimento no SiTef;
- identificação lógica do terminal;
- endereço/porta do servidor SiTef;
- parametrização/homologação das redes adquirentes;
- eventual arquivo de configuração e material criptográfico provisionado pelo fornecedor.

Configuração local prevista:

```env
TEF_DRIVER=sitef
SITEF_LIBRARY=C:\...\CliSiTef.dll
TEF_REAL_PAYMENTS_ENABLED=false
```

`TEF_REAL_PAYMENTS_ENABLED` deve continuar `false` até o teste de homologação. A primeira implementação real deve encapsular as chamadas oficiais de inicialização, continuação interativa, confirmação/não-confirmação, cancelamento e consulta de pendências. O PIN, PAN, CVV e trilhas nunca devem atravessar a API do agente.
