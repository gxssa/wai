module.exports = {
  apps: Array.from({ length: 55 }, (_, i) => ({
    name: 'wai-' + (i + 1),
    script: 'wai',
    args: 'run',
    instances: 1,
    autorestart: true,
    watch: false,
    env: {
      W_AI_API_KEY: 'wsk-xxx'
    }
  }))
};

