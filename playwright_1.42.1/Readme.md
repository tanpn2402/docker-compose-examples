
Using normal cmd:
```sh
docker run -it --rm --ipc=host -v /test_dir:/test_dir mcr.microsoft.com/playwright:v1.42.1-jammy /bin/bash -c "cd test_dir && npm i && URL=http://localhost:2930/ CI=true npx playwright test"
```