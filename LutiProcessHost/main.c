/* No network, registry or agent protocol. Own one child process group and reap
 * it on completion, SIGTERM, or loss of the owning application. */
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
static volatile sig_atomic_t stopping = 0;
static void on_signal(int s) { (void)s; stopping = 1; }
static void sleep_ms(long ms) { struct timespec t={ms/1000,(ms%1000)*1000000}; while(nanosleep(&t,&t)<0 && errno==EINTR){} }
static int reap_group(pid_t child) {
    kill(-child,SIGTERM);
    for(int i=0;i<20;i++) { if(kill(-child,0)<0 && errno==ESRCH)return 0; sleep_ms(25); }
    kill(-child,SIGKILL); return 0;
}
int main(int argc,char **argv) {
    if(argc<3 || argv[1][0]!='/' || argv[2][0]!='/') {
        fputs("Usage: LutiProcessHost /absolute/cwd /absolute/program [args...]\n",stderr); return 125;
    }
    pid_t owner=getppid();
    if(owner<=1)return 125;
    // Swift/Foundation may launch from a worker with signals masked. Installing
    // handlers alone does not unblock an inherited mask.
    sigset_t clear; sigemptyset(&clear); sigprocmask(SIG_SETMASK,&clear,NULL);
    struct sigaction action={0}; action.sa_handler=on_signal; sigemptyset(&action.sa_mask);
    sigaction(SIGTERM,&action,NULL); sigaction(SIGINT,&action,NULL); sigaction(SIGHUP,&action,NULL);
    if(chdir(argv[1])!=0) { perror("cwd"); return 125; }
    int barrier[2]; if(pipe(barrier)!=0) { perror("pipe"); return 125; }
    fcntl(barrier[0],F_SETFD,FD_CLOEXEC); fcntl(barrier[1],F_SETFD,FD_CLOEXEC);
    pid_t child=fork();
    if(child<0) { perror("fork"); return 125; }
    if(child==0) {
        close(barrier[1]);
        signal(SIGTERM,SIG_DFL);signal(SIGINT,SIG_DFL);signal(SIGHUP,SIG_DFL);
        signal(SIGPIPE,SIG_DFL);
        /* The parent establishes the group before releasing this barrier. One
         * owner avoids a redundant parent/child setpgid race. */
        char ready;
        if(read(barrier[0],&ready,1)!=1) { perror("process barrier"); _exit(125); }
        close(barrier[0]);
        execv(argv[2],&argv[2]);perror("exec");_exit(127);
    }
    close(barrier[0]);
    if(setpgid(child,child)!=0) {
        perror("setpgid");
        kill(child,SIGKILL);close(barrier[1]);waitpid(child,NULL,0);return 125;
    }
    if(write(barrier[1],"1",1)!=1)stopping=1;close(barrier[1]);
    int status=0; int reaped=0;
    while(!stopping && getppid()==owner) {
        pid_t done=waitpid(child,&status,WNOHANG);
        if(done==child){reaped=1;break;}
        if(done<0 && errno!=EINTR){stopping=1;break;}
        sleep_ms(25);
    }
    reap_group(child);
    if(!reaped) { while(waitpid(child,&status,0)<0 && errno==EINTR){} }
    if(stopping || getppid()!=owner)return 143;
    if(WIFEXITED(status))return WEXITSTATUS(status);
    if(WIFSIGNALED(status))return 128+WTERMSIG(status);
    return 125;
}
