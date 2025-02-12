# Runix Custom Coolify CI/CD

I made this script because I couldn't find a solution for the issue I had.

I started self-hosting around 7 months ago and use Coolify to handle builds and deployments. I was also using Cloudflare along with Coolify.

Whenever I push my updates on GitHub, Coolify automatically pulls the new code and builds & deploys the Docker image and container on my VPS. However, the build process is very resource-hungry, so I had to either upgrade my VPS to higher specs or build the Docker images somewhere else.

I didn't want to use GitHub Actions because I knew that I would quickly consume all the free build time available on the free plan.

So, I planned to build Docker images locally on my Mac and host a Docker registry on my VPS. This way, I can build locally and push to my own registry on the VPS.

But the issue is that some Docker images are over 100MB, so Cloudflare won't let me upload the Docker image on their free plan (I'd have to switch to enterprise to get an upload limit above 100MB).

I searched for a solution and didn’t find anything, so I decided to build my own. I don't know much about shell scripts, so I used ChatGPT to write one. It wasn't working at first, but after spending a few hours, I made it work—and it's very basic.

I've spent around 3 weeks testing and improving this script. For the last 7 days, I've been using it fully without any issues. I left a lot of comments in the script explaining what each line does, so just open the script and read through it to understand how it works.

One little bonus: I have around 8 projects, so I cloned this script 8 times and updated the variable values to suit each project. I even created an alias in my `.zshrc` file to execute the script when I run `runner-dev` in my terminal, so I simply run the command in my project folder where I have the Dockerfile.

<br />

## Notes
1. I only use Dockerfile-based deployment, so I haven't tested this with Docker Compose. I don't have any plans to add more features to this script because I want it to be fast and lightweight—so I won't be updating it unless I find any issues.

2. You have to run this script in the directory where your Dockerfile is located.

3. Make sure Docker is running on your system before executing this script.

<br />

## Screenshots
### Console Logs
![Console](/assets/console-logs.png)

### Discord Notifications
![Console](/assets/discord-notifications.png)

### Log Files
![Console](/assets/log-files.png)