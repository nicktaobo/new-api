server=DMIT_newapi
echo "deploying to prd..."
echo ">> making file..."
cd web
pnpm run build
wait
cd ..
echo ">> build backend..."
make build_prd
wait
scp -r new-api $server:~/new-api
wait
ssh $server "bash ~/new-api/start.sh"
echo ">> done!"
exit 0